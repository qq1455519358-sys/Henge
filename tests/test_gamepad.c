/* The DualShock 4 on the xHCI's port 7, driven the way macOS drives it: through the command
 * ring, endpoint 0 control transfers and interrupt transfers in guest memory, with the
 * shipped devices/xhci.c included directly (its statics and all).
 *
 * Checks the device and configuration descriptors (IDs, the HID descriptor's report length
 * against the report descriptor), walks the report descriptor's items to confirm the layout
 * the report builder assumes, answers to the feature reports drivers read at attach, the
 * bytes of input reports made from host states (sticks, hat, buttons, triggers), that a quick
 * tap survives a guest that reads late, that output reports complete, plug and unplug while
 * running, and the HV_NO_GAMEPAD kill switch.
 *
 * Needs no machine: the few engine calls xhci.c makes are stubbed below over a flat RAM
 * buffer, so this builds anywhere with only bt_hci.c and usb_camera.c beside it:
 *   clang -std=c11 -Wall -Wextra -O1 -g -Icore -Ihost -Idevices tests/test_gamepad.c \
 *     devices/bt_hci.c devices/usb_camera.c -lpthread -o test_gamepad
 */
#define _GNU_SOURCE /* clock_gettime and setenv under glibc's strict C11 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xhci.c"

/* ---- the engine, stubbed: guest RAM is one buffer ---- */

#define RAM_PA 0x10000000ull
#define RAM_SIZE (1u << 20)
static uint8_t ram[RAM_SIZE];

static int in_ram(uint64_t pa, uint64_t len) { return pa >= RAM_PA && pa - RAM_PA + len <= RAM_SIZE; }
void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) {
    (void)m;
    return in_ram(pa, len) ? ram + (pa - RAM_PA) : NULL;
}
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len) {
    (void)m;
    if (!in_ram(pa, len)) return -1;
    memcpy(buf, ram + (pa - RAM_PA), len);
    return 0;
}
int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len) {
    (void)m;
    if (!in_ram(pa, len)) return -1;
    memcpy(ram + (pa - RAM_PA), buf, len);
    return 0;
}
void hv_machine_wake(HvMachine *m) { (void)m; }
void hv_pci_init(HvPciDev *d, uint16_t vendor, uint16_t device, uint32_t class_rev, uint16_t sub_vendor,
                 uint16_t sub_device) {
    (void)d, (void)vendor, (void)device, (void)class_rev, (void)sub_vendor, (void)sub_device;
}
void hv_pci_add_bar(HvPciDev *d, int bar, uint64_t size, int is64) { (void)d, (void)bar, (void)size, (void)is64; }
int hv_pcie_attach(HvPcie *p, HvPciDev *d) { (void)p, (void)d; return 0; }
void hv_pci_set_intx(HvPciDev *d, int level) { (void)d, (void)level; }
void hv_pvg_lite_display_size(uint32_t *w, uint32_t *h) { *w = 0, *h = 0; }

/* ---- checks ---- */

static int checks, failures;
static void check(const char *what, long got, long want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %ld (0x%lx), expected %ld (0x%lx)\n", what, got, got, want, want);
        failures++;
    } else {
        printf("  ok   %s\n", what);
    }
}

/* ---- guest memory layout ---- */

#define DCBAA (RAM_PA + 0x00000)
#define CMD_RING (RAM_PA + 0x01000)
#define EVT_RING (RAM_PA + 0x10000)  /* 1024 events */
#define IN_CTX (RAM_PA + 0x04000)
#define OUT_CTX (RAM_PA + 0x05000)
#define EP0_RING (RAM_PA + 0x06000)  /* 256 TRBs, never wraps here */
#define IN_RING (RAM_PA + 0x08000)
#define OUT_RING (RAM_PA + 0x09000)
#define DATA (RAM_PA + 0x0a000)      /* control data stage */
#define REPORTS (RAM_PA + 0x0c000)   /* 64 bytes per IN transfer */
#define OUTDATA (RAM_PA + 0x0e000)

static HvMachine machine;
static unsigned cmd_i, ep0_i, in_i, out_i, evt_seen;

static void put_trb(uint64_t pa, uint64_t param, uint32_t status, uint32_t control) {
    uint32_t t[4] = {(uint32_t)param, (uint32_t)(param >> 32), status, control | 1u};
    hv_phys_write(&machine, pa, t, 16);
}
static void wr32(uint64_t pa, uint32_t v) { hv_phys_write(&machine, pa, &v, 4); }
static void wr64(uint64_t pa, uint64_t v) { hv_phys_write(&machine, pa, &v, 8); }
static void doorbell(HvXhci *x, int slot, int dci) { x->pci.bar_write(&x->pci, 0, DB + 4u * (unsigned)slot, (uint64_t)dci, 4); }

/* The next event, or 0 if none: returns its type and fills dw[4]. */
static int next_event(HvXhci *x, uint32_t dw[4]) {
    (void)x;
    hv_phys_read(&machine, EVT_RING + 16ull * evt_seen, dw, 16);
    if (!(dw[3] & 1)) return 0;
    evt_seen++;
    return (int)((dw[3] >> 10) & 0x3f);
}
static void drain_events(HvXhci *x) { uint32_t dw[4]; while (next_event(x, dw)) {} }

/* One command; returns its completion code and the slot it names. */
static int command(HvXhci *x, uint64_t param, uint32_t control, int *slot) {
    put_trb(CMD_RING + 16ull * cmd_i++, param, 0, control);
    doorbell(x, 0, 0);
    uint32_t dw[4];
    int type;
    while ((type = next_event(x, dw)) != 0)
        if (type == TRB_CMD_COMPLETION) {
            if (slot) *slot = (int)(dw[3] >> 24);
            return (int)(dw[2] >> 24);
        }
    return -1;
}

/* One control transfer on the slot's endpoint 0: SETUP, a data stage if len, STATUS. IN data
   lands at DATA. Returns the bytes the data stage moved, or -1 if the transfer stalled. */
static int control_xfer(HvXhci *x, int slot, uint8_t type, uint8_t req, uint16_t value, uint16_t index, uint16_t len) {
    uint8_t setup[8] = {type, req, (uint8_t)value, (uint8_t)(value >> 8), (uint8_t)index, (uint8_t)(index >> 8),
                        (uint8_t)len, (uint8_t)(len >> 8)};
    uint64_t sp;
    memcpy(&sp, setup, 8);
    int in = (type & 0x80) != 0;
    put_trb(EP0_RING + 16ull * ep0_i++, sp, 8, (uint32_t)TRB_SETUP << 10 | 1u << 6 | (uint32_t)(len ? (in ? 3 : 2) : 0) << 16);
    if (len) put_trb(EP0_RING + 16ull * ep0_i++, DATA, len, (uint32_t)TRB_DATA << 10 | 1u << 2 | (uint32_t)in << 16);
    put_trb(EP0_RING + 16ull * ep0_i++, 0, 0, (uint32_t)TRB_STATUS << 10 | 1u << 5 | (uint32_t)!in << 16);
    doorbell(x, slot, 1);
    uint32_t dw[4];
    int type_e, moved = len ? -2 : 0;
    while ((type_e = next_event(x, dw)) != 0) {
        if (type_e != TRB_TRANSFER_EVENT) continue;
        int cc = (int)(dw[2] >> 24);
        if (cc == CC_STALL) { /* what Set TR Dequeue does: skip the rest of the stalled transfer */
            x->slots[slot].ep[1].dequeue = EP0_RING + 16ull * ep0_i;
            return -1;
        }
        if (cc == CC_SHORT_PACKET) moved = len - (int)(dw[2] & 0xffffff);
    }
    if (moved == -2) moved = len; /* no short packet: all of it */
    return moved;
}

/* Post one 64-byte IN transfer on the controller's interrupt endpoint and let the CPU poll;
   returns the bytes it got (0 if none) into out. */
static int read_report(HvXhci *x, int slot, uint8_t out[64]) {
    uint64_t buf = REPORTS + 64ull * (in_i % 32);
    memset(out, 0, 64);
    hv_phys_write(&machine, buf, out, 64);
    put_trb(IN_RING + 16ull * in_i++, buf, 64, (uint32_t)TRB_NORMAL << 10 | 1u << 5 | 1u << 2);
    doorbell(x, slot, PAD_DCI_IN);
    hv_xhci_poll(x);
    uint32_t dw[4];
    int type, got = 0;
    while ((type = next_event(x, dw)) != 0)
        if (type == TRB_TRANSFER_EVENT && ((dw[3] >> 16) & 0x1f) == PAD_DCI_IN) got = 64 - (int)(dw[2] & 0xffffff);
    hv_phys_read(&machine, buf, out, 64);
    if (!got) in_i--; /* still posted and unread: the next read reuses it */
    return got;
}

/* ---- the report descriptor, item by item ---- */

/* Sums the bits each report declares and checks the collections close. Returns 0 if sane. */
static int walk_descriptor(const uint8_t *d, int n, int *in1, int *out5, int *f02, int *f12, int *fa3, int *depth_end) {
    int size = 0, count = 0, id = 0, depth = 0;
    *in1 = *out5 = *f02 = *f12 = *fa3 = 0;
    for (int i = 0; i < n;) {
        uint8_t b = d[i];
        int len = b & 3;
        if (len == 3) len = 4;
        if (b == 0xfe || i + 1 + len > n) return -1; /* long items: the DS4 has none */
        uint32_t v = 0;
        for (int k = 0; k < len; k++) v |= (uint32_t)d[i + 1 + k] << (8 * k);
        switch (b & 0xfc) {
        case 0x74: size = (int)v; break;  /* report size */
        case 0x94: count = (int)v; break; /* report count */
        case 0x84: id = (int)v; break;    /* report id */
        case 0xa0: depth++; break;        /* collection */
        case 0xc0: depth--; break;        /* end collection */
        case 0x80: if (id == 1) *in1 += size * count; break;   /* input */
        case 0x90: if (id == 5) *out5 += size * count; break;  /* output */
        case 0xb0:                                            /* feature */
            if (id == 0x02) *f02 += size * count;
            if (id == 0x12) *f12 += size * count;
            if (id == 0xa3) *fa3 += size * count;
            break;
        }
        i += 1 + len;
    }
    *depth_end = depth;
    return 0;
}

int main(void) {
    hv_bt_set_machine_uuid(NULL);
    unsetenv("HV_NO_GAMEPAD");
    setenv("HV_NO_BT", "1", 1); /* the dongle is not what this is about; its port stays empty */

    printf("scenario: no controller at power-on\n");
    hv_xhci_gamepad_set_connected(0);
    HvXhci *x = hv_xhci_create(&machine, NULL);
    check("seven root-hub ports in HCSPARAMS1", (long)(x->pci.bar_read(&x->pci, 0, 4, 4) >> 24), 7);
    check("seven ports in the Supported Protocol capability", (long)((x->pci.bar_read(&x->pci, 0, XECP + 8, 4) >> 8) & 0xff), 7);
    check("port 7 powered and empty", (long)x->pci.bar_read(&x->pci, 0, PORTREGS + 16 * 6, 4), PORT_PP);
    check("port 6 empty with HV_NO_BT", (long)(x->portsc[5] & PORT_CCS), 0);
    check("port 4 (the mouse) unchanged: connected, full speed",
          (long)(x->portsc[3] & (PORT_CCS | 0xfu << PORT_SPEED_SHIFT)), (long)(PORT_CCS | SPEED_FULL << PORT_SPEED_SHIFT));

    /* The guest's setup: DCBAA, a command ring, one event ring segment, then run. */
    wr64(DCBAA, 0);
    x->pci.bar_write(&x->pci, 0, OP + 0x30, DCBAA, 8);
    x->pci.bar_write(&x->pci, 0, OP + 0x18, CMD_RING | 1, 8);
    wr64(RAM_PA + 0x3000, EVT_RING);
    wr64(RAM_PA + 0x3008, 1024);
    x->pci.bar_write(&x->pci, 0, RT + 0x20 + 0x08, 1, 4);              /* ERSTSZ */
    x->pci.bar_write(&x->pci, 0, RT + 0x20 + 0x10, RAM_PA + 0x3000, 8); /* ERSTBA */
    x->pci.bar_write(&x->pci, 0, OP, 1, 4);                             /* run */
    drain_events(x); /* the connect changes of ports 1-5 */
    hv_xhci_poll(x);
    check("port 7 still empty after a poll", (long)(x->portsc[6] & PORT_CCS), 0);

    printf("scenario: a controller is connected while the Mac runs\n");
    hv_xhci_gamepad_set_connected(1);
    hv_xhci_poll(x);
    check("port 7 connected", (long)(x->portsc[6] & PORT_CCS), PORT_CCS);
    check("port 7 change bit set", (long)(x->portsc[6] & PORT_CSC), PORT_CSC);
    check("port 7 at full speed", (long)((x->portsc[6] >> PORT_SPEED_SHIFT) & 0xf), SPEED_FULL);
    uint32_t dw[4];
    int type = next_event(x, dw);
    check("a port status change event", type, TRB_PORT_STATUS);
    check("for port 7", (long)(dw[0] >> 24), 7);
    x->pci.bar_write(&x->pci, 0, PORTREGS + 16 * 6, PORT_CSC | PORT_PP, 4); /* acknowledge */
    x->pci.bar_write(&x->pci, 0, PORTREGS + 16 * 6, PORT_PR | PORT_PP, 4);  /* reset the port */
    drain_events(x);

    printf("scenario: enumeration\n");
    int slot = 0;
    check("Enable Slot", command(x, 0, (uint32_t)TRB_ENABLE_SLOT << 10, &slot), CC_SUCCESS);
    wr64(DCBAA + 8ull * (unsigned)slot, OUT_CTX);
    uint8_t zero[0x400] = {0};
    hv_phys_write(&machine, IN_CTX, zero, sizeof zero);
    wr32(IN_CTX + 4, 3);                           /* add the slot and EP0 */
    wr32(IN_CTX + 32, 1u << 27);                   /* slot: one context entry */
    wr32(IN_CTX + 32 + 4, 7u << 16);               /* root hub port 7 */
    wr32(IN_CTX + 64 + 4, 4u << 3 | 64u << 16);    /* EP0: control, 64 bytes */
    wr64(IN_CTX + 64 + 8, EP0_RING | 1);
    check("Address Device on port 7", command(x, IN_CTX, (uint32_t)TRB_ADDRESS_DEVICE << 10 | (uint32_t)slot << 24, NULL),
          CC_SUCCESS);
    check("the slot holds the controller", x->slots[slot].dev, HV_XDEV_PAD);

    uint8_t d[512];
    int n = control_xfer(x, slot, 0x80, 6, 0x0100, 0, 18);
    hv_phys_read(&machine, DATA, d, 18);
    check("device descriptor: 18 bytes", n, 18);
    check("vendor 0x054C (Sony)", d[8] | d[9] << 8, 0x054c);
    check("product 0x09CC (DualShock 4 v2)", d[10] | d[11] << 8, 0x09cc);
    check("no serial string", d[16], 0);

    n = control_xfer(x, slot, 0x80, 6, 0x0200, 0, 9);
    hv_phys_read(&machine, DATA, d, 9);
    check("configuration header: wTotalLength 41", d[2] | d[3] << 8, 41);
    n = control_xfer(x, slot, 0x80, 6, 0x0200, 0, 255);
    hv_phys_read(&machine, DATA, d, 41);
    check("whole configuration: 41 bytes", n, 41);
    check("interface: HID", d[9 + 5], 3);
    check("HID descriptor type", d[18 + 1], 0x21);
    int wdl = d[18 + 7] | d[18 + 8] << 8;
    check("HID descriptor's wDescriptorLength is the report descriptor's length", wdl, (long)sizeof pad_report_desc);
    check("the report descriptor is 507 bytes, as the real controller's", (long)sizeof pad_report_desc, 507);
    check("endpoint 0x84 IN interrupt", d[27 + 2] | d[27 + 3] << 8, 0x0384);
    check("endpoint 0x03 OUT interrupt", d[34 + 2] | d[34 + 3] << 8, 0x0303);

    n = control_xfer(x, slot, 0x80, 6, 0x0302, 0x0409, 255);
    hv_phys_read(&machine, DATA, d, 64);
    char product[32] = {0};
    for (int i = 0; i < 19 && 2 + 2 * i < n; i++) product[i] = (char)d[2 + 2 * i];
    check("product string is \"Wireless Controller\"", strcmp(product, "Wireless Controller"), 0);
    check("string 3 (no serial) stalls", control_xfer(x, slot, 0x80, 6, 0x0303, 0x0409, 255), -1);
    x->slots[slot].ep_running[1] = 1; /* what Reset Endpoint and a doorbell do after a stall */
    set_ep_state(x, slot, 1, 1);

    n = control_xfer(x, slot, 0x81, 6, 0x2200, 0, (uint16_t)wdl);
    hv_phys_read(&machine, DATA, d, (unsigned)wdl);
    check("report descriptor: all of it in one transfer", n, wdl);
    check("report descriptor bytes are pad_report_desc", memcmp(d, pad_report_desc, sizeof pad_report_desc), 0);
    int in1, out5, f02, f12, fa3, depth;
    check("report descriptor items parse", walk_descriptor(d, n, &in1, &out5, &f02, &f12, &fa3, &depth), 0);
    check("collections close", depth, 0);
    check("input report 1: 63 bytes after its ID", in1, 63 * 8);
    check("output report 5: 31 bytes after its ID", out5, 31 * 8);
    check("feature 0x02: 36 bytes after its ID", f02, 36 * 8);
    check("feature 0x12: 15 bytes after its ID", f12, 15 * 8);
    check("feature 0xA3: 48 bytes after its ID", fa3, 48 * 8);

    check("SET_CONFIGURATION 1", control_xfer(x, slot, 0x00, 9, 1, 0, 0), 0);
    check("SET_IDLE accepted", control_xfer(x, slot, 0x21, 0x0a, 0, 0, 0), 0);
    n = control_xfer(x, slot, 0xa1, 1, 0x0302, 0, 37);
    hv_phys_read(&machine, DATA, d, 37);
    check("feature 0x02 (calibration): 37 bytes", n, 37);
    check("feature 0x02 starts with its ID", d[0], 0x02);
    check("calibration: gyro pitch plus != minus", (int16_t)(d[7] | d[8] << 8) != (int16_t)(d[9] | d[10] << 8), 1);
    n = control_xfer(x, slot, 0xa1, 1, 0x0312, 0, 16);
    hv_phys_read(&machine, DATA, d, 16);
    check("feature 0x12 (pairing): 16 bytes, ID first", n * 256 + d[0], 16 * 256 + 0x12);
    n = control_xfer(x, slot, 0xa1, 1, 0x03a3, 0, 49);
    hv_phys_read(&machine, DATA, d, 49);
    check("feature 0xA3 (firmware): 49 bytes, ID first", n * 256 + d[0], 49 * 256 + 0xa3);
    uint8_t out_report[32] = {0x05, 0xff, 0x00, 0x00, 0x40, 0x40, 0x00, 0x00, 0xff};
    hv_phys_write(&machine, DATA, out_report, sizeof out_report);
    check("SET_REPORT output 0x05 (rumble, light) accepted", control_xfer(x, slot, 0x21, 9, 0x0205, 0, 32), 32);

    /* Configure Endpoint: EP4 IN (DCI 9) and EP3 OUT (DCI 6). */
    hv_phys_write(&machine, IN_CTX, zero, sizeof zero);
    wr32(IN_CTX + 4, 1u | 1u << PAD_DCI_IN | 1u << PAD_DCI_OUT);
    wr32(IN_CTX + 32, 9u << 27);
    wr32(IN_CTX + 32ull * (PAD_DCI_IN + 1) + 4, 7u << 3 | 64u << 16); /* interrupt IN */
    wr64(IN_CTX + 32ull * (PAD_DCI_IN + 1) + 8, IN_RING | 1);
    wr32(IN_CTX + 32ull * (PAD_DCI_OUT + 1) + 4, 3u << 3 | 64u << 16); /* interrupt OUT */
    wr64(IN_CTX + 32ull * (PAD_DCI_OUT + 1) + 8, OUT_RING | 1);
    check("Configure Endpoint", command(x, IN_CTX, (uint32_t)TRB_CONFIGURE_EP << 10 | (uint32_t)slot << 24, NULL), CC_SUCCESS);
    check("ready once the guest reads it", hv_xhci_gamepad_ready(x), 1);

    printf("scenario: input reports\n");
    uint8_t r[64];
    check("first report: the neutral state, at once", read_report(x, slot, r), 64);
    check("report ID 1", r[0], 1);
    check("sticks centred", r[1] == 0x80 && r[2] == 0x80 && r[3] == 0x80 && r[4] == 0x80, 1);
    check("hat neutral, no face button", r[5], 0x08);
    check("battery full on cable", r[30], 0x1b);
    check("no finger on the touch pad", r[35], 0x80);
    int counter0 = r[7] >> 2;
    check("nothing more without a change", read_report(x, slot, r), 0);

    hv_xhci_gamepad_state(x, HV_PAD_CROSS | HV_PAD_L1 | HV_PAD_R2 | HV_PAD_PS, 2, 0x00, 0xff, 0x40, 0xc0, 0x10, 0xfe);
    check("the new state comes in one report", read_report(x, slot, r), 64);
    check("left stick full left", r[1], 0x00);
    check("left stick full down", r[2], 0xff);
    check("right stick", r[3] << 8 | r[4], 0x40c0);
    check("hat right (2), cross (bit 5)", r[5], 0x22);
    check("L1 and R2 bits", r[6], 0x09);
    check("PS bit", r[7] & 3, 1);
    check("counter advanced", (r[7] >> 2) != counter0, 1);
    check("L2 travel", r[8], 0x10);
    check("R2 travel", r[9], 0xfe);

    printf("scenario: a tap between two reads of a busy guest\n");
    hv_xhci_gamepad_state(x, HV_PAD_CIRCLE, 8, 0x80, 0x80, 0x80, 0x80, 0, 0);
    hv_xhci_gamepad_state(x, HV_PAD_CIRCLE, 8, 0x90, 0x80, 0x80, 0x80, 0, 0); /* a stick move merges */
    hv_xhci_gamepad_state(x, 0, 8, 0x80, 0x80, 0x80, 0x80, 0, 0);
    read_report(x, slot, r);
    check("first: circle down", r[5], 0x48);
    check("with the merged stick move", r[1], 0x90);
    read_report(x, slot, r);
    check("then: released", r[5], 0x08);
    check("and nothing else queued", read_report(x, slot, r), 0);

    printf("scenario: output report on the interrupt OUT endpoint\n");
    hv_phys_write(&machine, OUTDATA, out_report, sizeof out_report);
    put_trb(OUT_RING + 16ull * out_i++, OUTDATA, 32, (uint32_t)TRB_NORMAL << 10 | 1u << 5);
    doorbell(x, slot, PAD_DCI_OUT);
    int out_done = 0;
    while ((type = next_event(x, dw)) != 0)
        if (type == TRB_TRANSFER_EVENT && ((dw[3] >> 16) & 0x1f) == PAD_DCI_OUT && (dw[2] >> 24) == CC_SUCCESS) out_done = 1;
    check("the OUT transfer completed", out_done, 1);

    printf("scenario: the controller goes away\n");
    hv_xhci_gamepad_state(x, HV_PAD_TRIANGLE, 8, 0x80, 0x80, 0x80, 0x80, 0, 0);
    hv_xhci_gamepad_set_connected(0);
    hv_xhci_poll(x);
    check("port 7 disconnected", (long)(x->portsc[6] & PORT_CCS), 0);
    check("with its change bit", (long)(x->portsc[6] & PORT_CSC), PORT_CSC);
    type = next_event(x, dw);
    check("a port status change event for port 7", type * 256 + (int)(dw[0] >> 24), TRB_PORT_STATUS * 256 + 7);
    check("not ready", hv_xhci_gamepad_ready(x), 0);
    check("the old slot gets nothing", read_report(x, slot, r), 0);
    hv_xhci_gamepad_set_connected(1);
    hv_xhci_poll(x);
    check("no plug-in before the guest acknowledges the unplug", (long)(x->portsc[6] & PORT_CCS), 0);
    x->pci.bar_write(&x->pci, 0, PORTREGS + 16 * 6, PORT_CSC | PORT_PP, 4);
    x->pad_replug_ns = camera_now() - 1; /* the settle time has passed */
    hv_xhci_poll(x);
    check("plugged in again after", (long)(x->portsc[6] & PORT_CCS), PORT_CCS);
    hv_xhci_destroy(x);

    printf("scenario: HV_NO_GAMEPAD keeps the port empty\n");
    setenv("HV_NO_GAMEPAD", "1", 1);
    hv_xhci_gamepad_set_connected(1);
    x = hv_xhci_create(&machine, NULL);
    hv_xhci_poll(x);
    check("port 7 empty though a controller is held", (long)x->portsc[6], PORT_PP);
    hv_xhci_gamepad_state(x, HV_PAD_CROSS, 0, 0, 0, 0, 0, 0, 0);
    check("states are dropped", (long)(x->pad_qtail - x->pad_qhead), 0);
    hv_xhci_destroy(x);
    unsetenv("HV_NO_GAMEPAD");

    printf("scenario: a controller held at power-on is there from the start\n");
    x = hv_xhci_create(&machine, NULL);
    check("port 7 connected at reset", (long)(x->portsc[6] & (PORT_CCS | PORT_CSC)), PORT_CCS | PORT_CSC);
    hv_xhci_destroy(x);

    printf("scenario: the other devices answer as before\n");
    x = hv_xhci_create(&machine, NULL);
    static const uint8_t get_config[8] = {0x80, 6, 0, 2, 0, 0, 255, 0};
    static const uint8_t get_serial[8] = {0x80, 6, 3, 3, 0x09, 0x04, 255, 0};
    static const uint8_t get_protocol[8] = {0xa1, 3, 0, 0, 0, 0, 1, 0};
    uint8_t reply[512];
    static const struct { int dev; const char *name; int protocol; } others[] = {
        {HV_XDEV_KBD, "keyboard", 1}, {HV_XDEV_TP, "trackpad", 1}, {HV_XDEV_MOUSE, "mouse", 0}, {HV_XDEV_TABLET, "tablet", 0},
    };
    for (unsigned i = 0; i < sizeof others / sizeof others[0]; i++) {
        char what[96];
        x->slots[1].dev = others[i].dev;
        snprintf(what, sizeof what, "%s: whole configuration is 34 bytes", others[i].name);
        check(what, control(x, 1, get_config, reply, 255), 34);
        snprintf(what, sizeof what, "%s: serial string 3 still answers (\"1\" or \"HengeVM\")", others[i].name);
        check(what, control(x, 1, get_serial, reply, 255) > 2, 1);
        snprintf(what, sizeof what, "%s: GET_PROTOCOL", others[i].name);
        control(x, 1, get_protocol, reply, 1);
        check(what, reply[0], others[i].protocol);
    }
    hv_xhci_destroy(x);

    printf("test_gamepad: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
