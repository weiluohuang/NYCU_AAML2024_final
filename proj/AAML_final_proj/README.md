## Requirment  
- java:  "1.8.0_432" 
- sbt: "1.10.6"
## Command
Please use following command when make prog:
* `make prog EXTRA_LITEX_ARGS="--cpu-variant=generate+csrPluginConfig:all+cfu+iCacheSize:65536+dCacheSize:131072+prediction:dynamic_target+safe:false+hardwareDiv:true"`
* `make load EXTRA_LITEX_ARGS="--cpu-variant=generate+csrPluginConfig:all+cfu+iCacheSize:65536+dCacheSize:131072+prediction:dynamic_target+safe:false+hardwareDiv:true"`

The average perfromance should be around this:

**Accuracy: 0.880%**
**Latency: 92262.23 us**
## Toolchains
- EXTRA_LITEX_ARGS above will install **sbt** and stuffs on first run.
