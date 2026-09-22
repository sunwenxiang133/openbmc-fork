# Findings

- HEAD 798de5bc2e contains Shell/ExternalSensor implementation. Stash 6f7d246d48 contains incomplete hwmon migration.
- Full stash apply aborted on untracked .vscode/settings.json. Applied scoped git diff via git apply --index successfully.
- Driver incorrectly treats hwmon device as embedded i2c_client; drvdata already stores client.
- Current HwmonTempMain uses supported type map, Bus/Address and Name/Name1; stash SysfsPath/InputName unsupported.
- Stash fan config monitors only Chip0 and removes the aggregate, losing remaining inputs.
- Stash deletes Host reconciliation. Unpowered mux/client probe needs retries after Host Running.
- Current DTS has no reset-gpios; no arbitrary reset timing fix will be added.
