set partNumber $::env(XILINX_PART)
set boardName  $::env(XILINX_BOARD)
set boardNameShort $::env(BOARD)

set ipName xlnx_mig_7_ddr3

create_project $ipName . -force -part $partNumber
set_property board_part $boardName [current_project]

create_ip -name mig_7series -vendor xilinx.com -library ip -module_name $ipName

exec cp mig_$boardNameShort.prj ./$ipName.srcs/sources_1/ip/$ipName/mig_a.prj

set_property -dict [list CONFIG.XML_INPUT_FILE {mig_a.prj} CONFIG.RESET_BOARD_INTERFACE {Custom} CONFIG.MIG_DONT_TOUCH_PARAM {Custom} CONFIG.BOARD_MIG_PARAM {Custom}] [get_ips $ipName]

generate_target {instantiation_template} [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
set ipXci [get_files  ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
set generateStatus [catch {
  generate_target all $ipXci
} generateError]
if {$generateStatus} {
  set generatedIpDir [file normalize ./$ipName.gen/sources_1/ip/$ipName]
  set tmpDeliveredDir [file join $generatedIpDir _tmp $ipName]
  set finalDeliveredDir [file join $generatedIpDir $ipName]
  set deliveredWrapper [file join $finalDeliveredDir user_design rtl $ipName.v]
  set tmpWrapper [file join $tmpDeliveredDir user_design rtl $ipName.v]

  if {[file exists $tmpWrapper] && ![file exists $deliveredWrapper]} {
    puts "RVMT: recovering MIG output delivery after Vivado rename failure"
    file rename -force $tmpDeliveredDir $finalDeliveredDir
  }

  if {![file exists $deliveredWrapper]} {
    error $generateError
  }
}
create_ip_run [get_files -of_objects [get_fileset sources_1] ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1
