#ifndef HENGEVM_XHCI_H
#define HENGEVM_XHCI_H

#include <pthread.h>

#include "bt_hci.h"
#include "pcie.h"
#include "usb_camera.h"

/* An xHCI USB host controller (xHCI 1.0, one interrupter, 32-byte contexts,
   INTx) with dedicated root-hub ports:
     Port 1 (dev 0): Apple USB HID boot keyboard
     Port 2 (dev 1): Apple Magic Trackpad 2 multitouch
     Port 3 (dev 2): UVC bulk Front/Back camera
     Port 4 (dev 3): 5-button wheel USB mouse
     Port 5 (dev 4): Absolute-position USB tablet / Apple Pencil digitizer
     Port 6 (dev 5): Broadcom BCM20702A0 USB Bluetooth HCI controller
     Port 7 (dev 6): Sony DualShock 4 (v2) game controller, while one is held to the host */
enum {
    HV_XDEV_KBD = 0,
    HV_XDEV_TP = 1,
    HV_XDEV_CAMERA = 2,
    HV_XDEV_MOUSE = 3,
    HV_XDEV_TABLET = 4,
    HV_XDEV_BT = 5,
    HV_XDEV_PAD = 6,
};
#define HV_XHCI_SLOTS 12
#define HV_XHCI_PORTS 7
#define HV_XHCI_DEVICES 7 /* indexes devs[]; HV_XDEV_BT's entry stays empty (the dongle has its own paths) */
#define HV_XHCI_INTRS 4
#define HV_XHCI_EPS 32 /* device context index 1..31 */
#define HV_XHCI_REPORTS 256

/* The Magic Trackpad 2's sensor, in its own units (a ~160 x 115 mm pad).
   hv_xhci_touch takes coordinates in these ranges. */
#define HV_TP_SENSOR_X 8134
#define HV_TP_SENSOR_Y 5206
#define HV_TP_FINGERS 10
#define HV_TP_REPORTS 64
#define HV_TP_REPORT_LEN (12 + 9 * HV_TP_FINGERS) /* report ID 2: 12-byte prefix, N x 9-byte fingers */
/* The mouse's report: buttons 1-5, X and Y (16 bits each, relative), wheel, horizontal pan. */
#define HV_MS_REPORT_LEN 7
#define HV_MS_REPORTS 128
/* The game controller's buttons, as hv_xhci_gamepad_state takes them: the DS4's own HID
   button order (buttons 1-14), so bits 0-3, 4-11 and 12-13 drop straight into report bytes
   5, 6 and 7. */
#define HV_PAD_SQUARE   (1u << 0)
#define HV_PAD_CROSS    (1u << 1)
#define HV_PAD_CIRCLE   (1u << 2)
#define HV_PAD_TRIANGLE (1u << 3)
#define HV_PAD_L1       (1u << 4)
#define HV_PAD_R1       (1u << 5)
#define HV_PAD_L2       (1u << 6)
#define HV_PAD_R2       (1u << 7)
#define HV_PAD_SHARE    (1u << 8)
#define HV_PAD_OPTIONS  (1u << 9)
#define HV_PAD_L3       (1u << 10)
#define HV_PAD_R3       (1u << 11)
#define HV_PAD_PS       (1u << 12)
#define HV_PAD_TOUCHPAD (1u << 13)
#define HV_PAD_REPORT_LEN 64 /* USB input report 0x01 */
#define HV_PAD_REPORTS 64

/* One state of the controller: what a report is built from when the guest takes it. */
typedef struct HvPadState {
    uint32_t buttons;           /* HV_PAD_* */
    uint8_t hat;                /* 0 up, clockwise to 7 up-left; 8 none */
    uint8_t lx, ly, rx, ry;     /* 0x80 centred, 0x00 left/up */
    uint8_t l2, r2;             /* trigger travel, 0..255 */
} HvPadState;

typedef struct HvXhciRing {
    uint64_t dequeue; /* guest PA of the next TRB */
    int ccs;          /* consumer cycle state */
} HvXhciRing;

typedef struct HvXhci {
    HvPciDev pci;
    HvMachine *m;
    /* operational */
    uint32_t usbcmd, usbsts, dnctrl, config;
    uint64_t dcbaap;
    HvXhciRing cmd;
    int cmd_running;
    uint32_t portsc[HV_XHCI_PORTS];
    /* interrupters and their event rings (macOS's driver wants at least three) */
    struct HvXhciIntr {
        uint32_t iman, imod, erstsz;
        uint64_t erstba, erdp;
        uint64_t seg_base;  /* current event ring segment */
        uint32_t seg_size, seg_index, index;
        int pcs;
    } intr[HV_XHCI_INTRS];
    /* device slots: -1 until the device on the slot's port is addressed */
    int slot_used[HV_XHCI_SLOTS + 1];
    struct HvXhciSlot {
        int dev;         /* HV_XDEV_*, or -1 none */
        uint64_t camera_generation;
        uint64_t pad_generation;     /* the controller's plug-in this slot was addressed for */
        int configured;
        HvXhciRing ep[HV_XHCI_EPS];
        int ep_running[HV_XHCI_EPS];
        uint8_t setup[8], control_data[512];
        uint32_t control_len, control_offset;
        int control_stalled;
    } slots[HV_XHCI_SLOTS + 1];
    HvUsbCamera camera;
    uint64_t camera_reconnect_ns; /* CPU-owned: resolution change reconnects port 3 */
    uint64_t camera_generation;
    /* keyboard reports waiting for an IN transfer (8 bytes each) */
    pthread_mutex_t mu;
    uint8_t reports[HV_XHCI_REPORTS][8];
    uint32_t rhead, rtail;
    uint8_t state[8];      /* modifiers, reserved, six keys: the current report */
    uint64_t delivered;
    /* Magic Trackpad 2: the fingers on the pad and their reports (Apple
       multitouch format, report ID 2: 12-byte prefix plus 9 bytes a finger). */
    struct HvTpFinger {
        int in;
        int id;        /* the report's 4-bit touch ID, 1..15 */
        int x, y;      /* sensor coordinates, 0..HV_TP_SENSOR_X/Y */
        uint8_t state; /* the report's 3-bit state: 0 none, 3 near, 4 contact, 7 stop */
    } tp_fingers[HV_TP_FINGERS];
    int tp_button;     /* the pad's full press (report byte 1, bit 0) */
    uint32_t tp_ts;    /* the report timestamp, one per report */
    uint8_t tp_reports[HV_TP_REPORTS][HV_TP_REPORT_LEN];
    uint8_t tp_rlen[HV_TP_REPORTS];
    uint32_t tp_rhead, tp_rtail;
    int tp_mt;         /* the guest switched us to multitouch mode (feature report 2) */
    uint64_t tp_delivered;
    uint32_t tp_reqs;   /* control requests logged, capped */
    uint32_t tp_db;     /* doorbells logged, capped */
    uint32_t tp_multi_logs; /* multi-finger deliveries logged, capped */
    uint8_t tp_f1[8];   /* feature report 1: the header for the selected sensor register */
    int tp_f1_len;
    /* The mouse on port 4: its reports, oldest first, and the buttons held now. */
    uint8_t ms_reports[HV_MS_REPORTS][HV_MS_REPORT_LEN];
    uint32_t ms_rhead, ms_rtail;
    uint8_t ms_buttons;
    int ms_unplugged; /* HV_USB_MOUSE=0: nothing on port 4 */
    /* The tablet (port 5): a generated report descriptor and a single
       latest-state slot. Absolute positions coalesce here, never queue. */
    uint8_t tab_desc[70];
    int tab_desc_len;
    uint16_t tab_xmax, tab_ymax; /* clamp bounds the descriptor was built with */
    uint8_t tab_buttons;
    uint16_t tab_x, tab_y;
    int tab_wheel;               /* accumulated wheel delta awaiting emission */
    int tab_dirty;
    uint64_t tab_delivered;
    /* The Bluetooth HCI dongle (port 6): its own slot, rings, and lock. */
    pthread_mutex_t bt_mu;
    int bt_present;              /* 0 only with HV_NO_BT */
    int bt_slot;
    HvXhciRing bep[HV_XHCI_EPS];
    int bep_running[HV_XHCI_EPS];
    int bt_configured;
    uint8_t bt_alt[4];
    HvBtHci bt;
    /* The game controller (port 7). Whether one is held to the host is a process-wide
       level (hv_xhci_gamepad_set_connected); pad_present is what the port shows the guest,
       and only hv_xhci_poll (the CPU thread) moves it, the way the camera reconnects. */
    int pad_disabled;            /* HV_NO_GAMEPAD: the port stays empty */
    int pad_present;
    uint64_t pad_generation;     /* one more at each unplug: slots addressed before it are stale */
    uint64_t pad_replug_ns;      /* no plug-in again before this (host monotonic clock) */
    /* Under mu: the latest state, and the states waiting for an IN transfer. Stick moves
       merge into the newest waiting state; a button or hat change always gets one of its
       own, so a quick tap is never lost between two reads of a busy guest. */
    HvPadState pad_cur;
    HvPadState pad_q[HV_PAD_REPORTS];
    uint32_t pad_qhead, pad_qtail;
    uint8_t pad_counter;         /* the report's 6-bit frame counter */
    uint32_t pad_reqs;           /* control requests logged, capped */
    uint64_t pad_delivered;
} HvXhci;

HvXhci *hv_xhci_create(HvMachine *m, HvPcie *bus);
void hv_xhci_destroy(HvXhci *x);
/* Any thread: a key went down or up (HID usage page 7 usage, e.g. 4 = A; 0xe0-0xe7 are modifiers). */
void hv_xhci_key(HvXhci *x, uint8_t usage, int down);
/* The same, by Linux input key code (what the host UI produces). */
void hv_xhci_key_linux(HvXhci *x, uint16_t code, int down);
/* Any thread: a Magic Trackpad 2 touch. phase: 0 down, 1 move, 2 up. id: a
   stable 1..15 for this touch; x, y in sensor units (HV_TP_SENSOR_*). Down and up
   report at once; a move only updates the finger, and hv_xhci_touch_frame commits
   one report for all the fingers that moved together. ts_ms is the touch sample's
   own clock (ms); the guest divides position deltas by timestamp deltas to get
   speed, so it must be the sample time, not the moment we happen to process it. */
void hv_xhci_touch(HvXhci *x, int id, int phase, int px, int py, uint32_t ts_ms);
/* Any thread: send one frame with every finger's current state (ends a move batch),
   stamped with the touch sample's own clock (ms). */
void hv_xhci_touch_frame(HvXhci *x, uint32_t ts_ms);
/* Any thread: the pad's full press (a click), down or up. */
void hv_xhci_touch_button(HvXhci *x, int down);
/* Any thread: the mouse moved, scrolled or both. wheel is positive away from the user, pan
   positive to the right, both in detents. Moves are merged while the guest hasn't taken them. */
void hv_xhci_mouse(HvXhci *x, int dx, int dy, int wheel, int pan);
/* Any thread: the mouse's buttons, bit 0 primary, 1 secondary, 2 middle, 3 back, 4 forward. */
void hv_xhci_mouse_buttons(HvXhci *x, unsigned buttons);
/* Whether the guest has configured the mouse and is reading it: until then its input belongs elsewhere. */
int hv_xhci_mouse_ready(const HvXhci *x);
/* Any thread: the tablet's latest state (absolute position, button, wheel). */
void hv_xhci_tablet_move(HvXhci *x, uint16_t px, uint16_t py);
void hv_xhci_tablet_button(HvXhci *x, int button, int down);
void hv_xhci_tablet_wheel(HvXhci *x, int dy);
/* Any thread: CoreBluetooth host radio bridge for the USB Bluetooth HCI controller. */
int hv_xhci_bt_scan_active(HvXhci *x);
int hv_xhci_bt_inject_adv(HvXhci *x, uint8_t addr_type, const uint8_t addr[6], int8_t rssi,
                          const uint8_t *adv_data, uint32_t adv_len);
int hv_xhci_bt_adv_active(HvXhci *x, uint8_t *out, uint32_t cap, uint32_t *out_len);
/* Any thread, even with no machine running: whether a game controller is held to the host.
   The xHCI plugs its DualShock 4 into port 7 (or pulls it) at its next poll, and one created
   later starts with the port in that state. HV_NO_GAMEPAD keeps the port empty regardless. */
void hv_xhci_gamepad_set_connected(int connected);
/* Any thread: the controller's state now. hat 0..7 (up, clockwise), anything else none;
   sticks 0x80 centred with 0x00 left/up; triggers 0..255. */
void hv_xhci_gamepad_state(HvXhci *x, uint32_t buttons, int hat, uint8_t lx, uint8_t ly, uint8_t rx, uint8_t ry,
                           uint8_t l2, uint8_t r2);
/* Whether the guest has configured the controller and is reading it. */
int hv_xhci_gamepad_ready(const HvXhci *x);
/* CPU thread: hand waiting reports to the guest. */
void hv_xhci_poll(HvXhci *x);
/* CPU stopped: rebase host deadlines and discard pre-pause camera images. */
void hv_xhci_resume(HvXhci *x);

#endif
