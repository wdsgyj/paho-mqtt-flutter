#include "test_config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); abort(); } } while (0)
static const mqtt_core_api *api;
static mqtt_event *next(uint64_t client) {
    struct timespec wait = {0, 10000000};
    for (int i=0; i<2500; i++) {
        mqtt_event *e=NULL;
        int rc=api->event_take(client,&e);
        CHECK(rc>=0);
        if (rc) return e;
        nanosleep(&wait,NULL); /* Bounded test harness wait only. */
    }
    abort();
}
int main(void) {
    api=mqtt_get_api(2)->core;
    CHECK(api && (api->capabilities & MQTT_CAP_ERRORS));
    mqtt_config cfg={0}; cfg.struct_size=sizeof(cfg);
    cfg.server_uri="tcp://mqtt-sdk-retry-check.invalid:1883"; cfg.client_id="retry-error-check";
    cfg.keep_alive_seconds=10; cfg.connect_timeout_seconds=4; cfg.clean_session=1;
    cfg.automatic_reconnect=1; cfg.min_retry_seconds=1; cfg.max_retry_seconds=1;
    mqtt_config_v2 options = test_config(cfg);
    uint64_t client=0; CHECK(mqtt_get_api(2)->create(&options,&client)==0);
    mqtt_event *e=next(client); CHECK(e->type==MQTT_EVENT_RESULT && e->code==0); api->event_release(e);
    CHECK(api->submit(client,1,MQTT_OP_CONNECT,NULL,NULL,0,0,0)==0);
    int results=0,failures=0;
    while (failures<2 || !results) {
        e=next(client);
        if (e->type==MQTT_EVENT_CONNECT_FAILED) {
            CHECK(e->error && e->error->category==MQTT_ERR_DNS && e->error->reason==MQTT_REASON_DNS_FAILURE);
            CHECK(e->error->flags & MQTT_ERROR_WILL_RETRY);
            CHECK(e->error->flags & MQTT_ERROR_DNS);
            CHECK(e->error->attempt_id==(uint64_t)++failures);
        } else if (e->type==MQTT_EVENT_RESULT) {
            CHECK(e->request_id==1 && e->code==0 && !e->error);
            CHECK(++results==1);
        } else CHECK(e->type==MQTT_EVENT_RECONNECTING);
        api->event_release(e);
    }
    /* Auto retries must never reuse the already-freed original request context. */
    CHECK(api->submit(client,2,MQTT_OP_CLOSE,NULL,NULL,0,0,0)==0);
    for (;;) {
        e=next(client); int done=e->type==MQTT_EVENT_RESULT && e->request_id==2;
        api->event_release(e); if (done) break;
    }
    CHECK(api->release_client(client)==0);
    puts("Start accepted once + event-only repeated initial DNS retries passed");
    return 0;
}
