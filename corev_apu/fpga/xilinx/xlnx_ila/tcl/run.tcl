set partNumber $::env(XILINX_PART)
set boardName  $::env(XILINX_BOARD)

set ipName xlnx_ila

proc rvmt_env_or_default {name default} {
  if {[info exists ::env($name)]} {
    set value [string trim $::env($name)]
    if {[string length $value] > 0} {
      return $value
    }
  }
  return $default
}

set dataDepth [rvmt_env_or_default RVMT_ILA_DATA_DEPTH 8192]
set inputPipeStages [rvmt_env_or_default RVMT_ILA_INPUT_PIPE_STAGES 2]
set storageQual [rvmt_env_or_default RVMT_ILA_STORAGE_QUAL 1]
set advTrigger [rvmt_env_or_default RVMT_ILA_ADV_TRIGGER TRUE]

puts "RVMT_ILA_DATA_DEPTH=$dataDepth"
puts "RVMT_ILA_INPUT_PIPE_STAGES=$inputPipeStages"
puts "RVMT_ILA_STORAGE_QUAL=$storageQual"
puts "RVMT_ILA_ADV_TRIGGER=$advTrigger"

create_project $ipName . -force -part $partNumber
set_property board_part $boardName [current_project]

create_ip -name ila -vendor xilinx.com -library ip -module_name $ipName
set_property -dict [list  CONFIG.C_NUM_OF_PROBES {3} \
                          CONFIG.C_PROBE0_WIDTH {1} \
                          CONFIG.C_PROBE1_WIDTH {136} \
                          CONFIG.C_PROBE2_WIDTH {484} \
                          CONFIG.C_DATA_DEPTH $dataDepth \
                          CONFIG.C_INPUT_PIPE_STAGES $inputPipeStages \
                          CONFIG.C_EN_STRG_QUAL $storageQual \
                          CONFIG.C_ADV_TRIGGER $advTrigger \
                    ] [get_ips $ipName]


generate_target {instantiation_template} [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
generate_target all [get_files  ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
create_ip_run [get_files -of_objects [get_fileset sources_1] ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1
