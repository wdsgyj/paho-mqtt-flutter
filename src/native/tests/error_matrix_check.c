/* Native half of the error fixture; servers and Dart tests are driven by Go. */
#include "test_config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); abort(); } } while (0)
static const mqtt_api_v2 *v;
static const mqtt_core_api *a;
static uint64_t handles[16];
static int count;
static mqtt_event *next(uint64_t h) {
    struct timespec wait={0,10000000};
    for(int i=0;i<2500;i++){mqtt_event *e=NULL;int rc=a->event_take(h,&e);CHECK(rc>=0);if(rc)return e;nanosleep(&wait,NULL);}
    fprintf(stderr,"timeout\n");abort();
}
static uint64_t client(const char *uri,const char *ca,int automatic){
    mqtt_config cfg={0};cfg.struct_size=sizeof(cfg);cfg.server_uri=uri;
    char id[32];snprintf(id,sizeof(id),"error-%d",count);cfg.client_id=id;
    cfg.keep_alive_seconds=5;cfg.connect_timeout_seconds=4;cfg.clean_session=1;
    cfg.automatic_reconnect=automatic;cfg.min_retry_seconds=1;cfg.max_retry_seconds=1;cfg.trust_store=ca;
    mqtt_config_v2 options=test_config(cfg);uint64_t h=0;CHECK(v->create(&options,&h)==0);handles[count++]=h;
    mqtt_event *e=next(h);CHECK(e->type==MQTT_EVENT_RESULT&&e->code==0);a->event_release(e);
    CHECK(a->submit(h,1,MQTT_OP_CONNECT,NULL,NULL,0,0,0)==0);return h;
}
static mqtt_error failure(uint64_t h,int category,int reason,int automatic){
    int admitted=0,failed=0;mqtt_error result={0};
    while(!admitted||!failed){mqtt_event *e=next(h);if(e->type==MQTT_EVENT_RESULT){CHECK(e->code==0&&!e->error);admitted=1;}
      if(e->type==MQTT_EVENT_CONNECT_FAILED){CHECK(e->error);result=*e->error;failed=1;}a->event_release(e);}
    CHECK(result.category==category&&result.reason==reason);CHECK(result.attempt_id==1&&result.operation==1&&result.message[0]);
    CHECK(!!(result.flags&32)==automatic);return result;
}
static const char *env(const char *key){const char *v=getenv(key);CHECK(v);return v;}
int main(void){v=mqtt_get_api(2);a=v->core;CHECK(a->capabilities&MQTT_CAP_ERRORS);
    const char *ca=env("MQTT_ERROR_CA");uint64_t network=client(env("MQTT_ERROR_REFUSED"),NULL,1),dns=client(env("MQTT_ERROR_DNS"),NULL,1),tls=client(env("MQTT_ERROR_MISMATCH"),ca,0);
    CHECK(failure(network,4,8,1).flags&1);CHECK(failure(dns,3,7,1).flags&2);CHECK(failure(tls,5,17,0).verify_code!=0);
    for(int i=0;i<2;i++){uint64_t h=i?dns:network;for(;;){mqtt_event *e=next(h);int done=e->type==MQTT_EVENT_CONNECT_FAILED;if(done){CHECK(e->error->attempt_id>=2&&e->error->flags&32);}a->event_release(e);if(done)break;}}
    mqtt_error handshake=failure(client(env("MQTT_ERROR_BADTLS"),NULL,0),5,14,0);CHECK(handshake.flags&4&&handshake.details[0]);
    failure(client(env("MQTT_ERROR_REJECT"),NULL,0),6,19,0);
    CHECK(failure(client(env("MQTT_ERROR_STALL"),NULL,0),4,9,0).elapsed_ms>=2000);
    CHECK(failure(client(env("MQTT_ERROR_TLS"),"/mqtt-does-not-exist/ca.pem",0),5,13,0).details[0]);
    CHECK(failure(client(env("MQTT_ERROR_TLS"),NULL,0),5,15,0).flags&(8|16));
    for(int i=0;i<count;i++){uint64_t h=handles[i];CHECK(a->submit(h,2,MQTT_OP_CLOSE,NULL,NULL,0,0,0)==0);for(;;){mqtt_event *e=next(h);int done=e->type==MQTT_EVENT_RESULT&&e->request_id==2;a->event_release(e);if(done)break;}CHECK(a->release_client(h)==0);}
    puts("Native structured error snapshots passed");return 0;
}
