# Connect the iPad app

Start the computer server:

```bash
./scripts/run-computer.sh
```

With the normal `NotesHotspot` profile, enter this in the iPad app:

```text
http://10.42.0.1:8000
```

On an existing LAN:

```bash
./scripts/run-computer.sh --no-hotspot
hostname -I
```

Use the computer's private LAN address with port `8000`.
