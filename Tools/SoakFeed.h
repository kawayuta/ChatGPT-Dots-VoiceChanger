#pragma once
#include "../Sources/RealtimeBridge.h"
typedef struct DVCSoakFeed DVCSoakFeed;
DVCSoakFeed *dvc_soak_feed_start(CVPBridge *bridge, double rate);
void dvc_soak_feed_stop(DVCSoakFeed *feed);
