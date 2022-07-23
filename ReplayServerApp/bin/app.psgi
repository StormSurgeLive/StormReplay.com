#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use StormSurgeLive::ReplayServer;

StormSurgeLive::ReplayServer->to_app;
