## Z-Stack Emulator

This repository contains a tiny asyncio-based Python server that emulates a TI
Z-Stack / ZNP coordinator over a TCP socket. The implementation is intentionally
minimal: it only answers the subset of Monitor/Test commands that zigbee2mqtt
(`zigbee-herdsman` with the `zstack` driver) needs during start-up. That allows
zigbee2mqtt to come online and exposes a coordinator, but the adapter never
announces devices or produces meaningful radio traffic.

### Running the emulator

This repository uses [uv](https://github.com/astral-sh/uv) script mode so no
virtualenv management is required. Run the emulator with:

```bash
uv run zstackmulator.py --host 127.0.0.1 --port 6638 --log-level DEBUG
```

Point zigbee2mqtt at the TCP socket via `configuration.yaml`:

```yaml
serial:
  port: tcp://127.0.0.1:6638
```

Start the emulator first, then launch zigbee2mqtt. The logs should show the fake
coordinator booting (reset indication, device info, etc.), but no devices will
ever be discovered.

### Development with Docker Compose

For local development and testing, a full stack is available with zigbee2mqtt and MQTT:

```bash
docker compose up
```

This starts:
- **zstackmulator**: The Z-Stack emulator on port 6638
- **mosquitto**: MQTT broker on port 1883
- **zigbee2mqtt**: With frontend on http://localhost:8081

The docker-compose setup is for development only. For production, deploy to Kubernetes.

### Kubernetes Deployment

Deploy using Kustomize (built into kubectl):

```bash
# Deploy
make install
# or manually:
kubectl apply -k .

# Check status
make status

# View logs
make logs

# Remove
make uninstall
# or manually:
kubectl delete -k .
```

The deployment uses the `ghcr.io/astral-sh/uv:debian` image (no custom container needed)
and creates:
- **Namespace**: `zstackmulator`
- **ConfigMap**: Contains the Python script
- **Deployment**: Single replica running the adapter
- **Service**: ClusterIP on port 6638

Configure zigbee2mqtt to connect to:

```yaml
serial:
  port: tcp://zstackmulator.zstackmulator.svc.cluster.local:6638
```

See [k8s/README.md](k8s/README.md) for more deployment options.

### Extending behaviour

The script keeps a tiny in-memory NV storage (see `DEFAULT_NV`) and has handler
stubs for the most common `SYS`, `UTIL`, `AF`, and `ZDO` commands. If your
zigbee2mqtt build uses additional commands, add them to the relevant handler
method. Unknown commands currently log a warning and receive a generic success
status, which is usually enough for management requests that only expect a
single status byte.

The emulator purposely keeps the NV store empty so zigbee-herdsman will
initialize every item it cares about; the data you write (network key, channel,
etc.) stays only in memory until you restart the script.
