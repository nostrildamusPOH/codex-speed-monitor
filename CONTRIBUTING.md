# Contributing

Use Discussions for questions, ideas and feedback. When reporting a reproducible
bug in Issues, include the monitor version, macOS version, Mac architecture,
steps to reproduce, and what you expected to see.

Remove local paths, identifiers and any private data from screenshots or command
output. Keep raw databases and logs off GitHub. See [Security and privacy](SECURITY.md).

Before sending a code change, run the relevant local checks from the repository
root:

```sh
python3 tests/test_pipeline.py
python3 tests/test_stream_identity.py
./scripts/test_recent_speed.sh
./scripts/test_sharing_integrated.sh
./scripts/test_sharing_lifecycle.sh
./scripts/build_app.sh
```
