peridio.json opts

```
  "shadow": {
    "executable": "bash",
    "args": [
      "/etc/peridiod/shadow.sh"
    ],
    "interval": 5000,
    "enabled": true
  }
```

peridio config keys

```
            shadow_executable: nil,
            shadow_args: [],
            shadow_interval: 10_000,
            shadow_enabled: false
```

example script

`support/shadow.sh`
