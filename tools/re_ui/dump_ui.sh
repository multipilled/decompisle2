#!/usr/bin/env bash
# N3 gameplay/UI audit: JSON dumps of DI2's UI, skill, loot, inventory and options data, plus raw bytes of sample SWFs.
# Run: tools/with_cpu.sh di2-gp-audit tools/re_ui/dump_ui.sh   (outputs under extracted/json and extracted/raw)
set -e
cd .
X=tools/di2x.sh
$X json 'DI2/UI/(HUD|Menus|Screens|Data|Shared|WheelData)/.*(BP_|DA_|DT_)[^/]*$'
$X json 'DI2/Horde/UI/.*(BP_|DA_)[^/]*$'
$X json 'DI2/BalancingData/(Player/Skills|Loot|Inventory|Player/Stamina|Player/Movement)/'
$X json 'DI2/Core/(OptionsSystem|Player/Inventory)/'
$X json 'DI2/Horde/BalancingData/(Player|Loot)/'
$X raw '/(SWF_HUD_Stamina|SWF_MenuViewSkillCards|SWF_Icons_Items)\.'
