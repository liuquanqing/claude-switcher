#include <mach/mach.h>
#include <mach/task_info.h>
#include <stdint.h>
#include <string.h>

// The caller's own disposable test process only. No other process is inspected.
int fixture_self_audit_token(uint8_t *destination) {
    audit_token_t token = {0};
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_AUDIT_TOKEN,
                                     (task_info_t)&token, &count);
    if (status != KERN_SUCCESS || sizeof(token) != 32) return -1;
    memcpy(destination, &token, sizeof(token));
    return 0;
}
