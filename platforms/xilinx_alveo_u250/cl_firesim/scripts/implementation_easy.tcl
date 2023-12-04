variable impl_run [get_runs impl_1]
variable WNS -1
variable WHS -1

reset_runs ${impl_run}
launch_runs ${impl_run} -to_step route_design -jobs ${jobs}
wait_on_run ${impl_run}

if {[get_property PROGRESS ${impl_run}] != "100%"} {
    puts "ERROR: implementation failed"
    exit 1
}

set WNS [get_property STATS.WNS ${impl_run}]
set WHS [get_property STATS.WHS ${impl_run}]

if {$WNS < 0 || $WHS < 0} {
    puts "ERROR: did not meet timing!"
    exit 1
}

launch_runs ${impl_run} -next_step -jobs ${jobs}
wait_on_run ${impl_run}

if {[get_property PROGRESS ${impl_run}] != "100%"} {
    puts "ERROR: implementation failed"
    exit 1
}
