#!/usr/bin/env bash
# Screamer scream: action / state-machine / notify Blueprints (bytecode) + intensity curves and explosion data set.
cd .
tools/re_ai/bpdump.sh 'Screamer/BP_Action_Scream|Screamer/BP_AnimNotify_SpawnExplosion|Enemies/BP_AnimNotify_SpawnExplosion' > extracted/ghidra_ai/bp_scream.log 2>&1
tools/di2x.sh json 'Screamer/(Curve_ScreamIntensity|DA_DataSetCollection_Explosions|DA_ActionDefinition|DA_AnimSet_.*Scream|DA_MovementSpeedModifier)' > extracted/ghidra_ai/json_scream.log 2>&1
grep -c "^ok" extracted/ghidra_ai/bp_scream.log extracted/ghidra_ai/json_scream.log
