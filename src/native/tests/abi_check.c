#include "mqtt_api_v2.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    if (mqtt_get_api(0) || mqtt_get_api(1) || mqtt_get_api(3))
        return 1;
    const mqtt_api_v2 *v2 = mqtt_get_api(2);
    if (!v2) return 2;
    const mqtt_core_api *api = v2->core;
    if (!api || api->abi_version != MQTT_CORE_API_VERSION || api->struct_size != sizeof(*api) ||
        !api->paho_version || !(api->capabilities & MQTT_CAP_CLIENT))
        return 2;
    if (!v2 || v2->abi_version != 2 || v2->struct_size != sizeof(*v2) || v2->core != api ||
        !v2->create || !v2->publish || !v2->subscribe || !v2->unsubscribe || !v2->disconnect ||
        !v2->disconnect_with_will || !v2->disconnect_unspecified ||
        !v2->disconnect_implementation || !v2->event_details)
        return 4;
    const char *version = api->paho_version();
    if (!version || !*version || strcmp(version, "unknown") == 0)
        return 3;
    printf("C ABI v%u, Paho %s, table size %u\n", api->abi_version, version, api->struct_size);
    return 0;
}
