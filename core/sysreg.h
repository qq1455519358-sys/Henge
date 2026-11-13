#ifndef HENGEVM_SYSREG_H
#define HENGEVM_SYSREG_H

#include <stdint.h>

#include "cpu.h"

/* MRS, MSR (register and immediate), and SYS (DC, IC, TLBI, AT).
   Each returns 1 if the block must leave. */
int hv_sysreg_mrs(HvCpu *cpu, uint32_t insn, uint64_t pc);
int hv_sysreg_msr(HvCpu *cpu, uint32_t insn, uint64_t pc);
int hv_sysreg_sys(HvCpu *cpu, uint32_t insn, uint64_t pc);

/* The guest's counter (CNTPCT): host mach_absolute_time, which runs at 24 MHz. */
uint64_t hv_counter(void);

/* One TLBI on one CPU's own TLB and branch cache. */
void hv_tlbi_apply(HvCpu *cpu, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2, uint64_t xt);

/* The CPU the guest is told it has (MIDR, ID_AA64ISAR1): M1's, plus the BF16 and I8MM the host runs
   natively unless HV_CPU_FEATURES=m1, with HV_MIDR=m4 for M4's identity. Run before each machine starts,
   as the environment can change between starts. */
void hv_sysreg_configure(void);

/* The same choice as text ("midr 0x611f0220 bf16 i8mm"), worked out from the environment and host now,
   for what a saved machine must match before it is resumed. */
const char *hv_sysreg_signature(void);

#endif
