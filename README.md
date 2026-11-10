# DynDNS for Route53

A small DynDNS service that lets a FRITZ!Box keep the `jkandler.de` A record up
to date:

```text
FRITZ!Box -> API Gateway HTTP API -> Lambda -> Route53 A record
```

## Documentation

Setup, operations and design notes, including the sections code comments refer to:
[`docs/README.md`](docs/README.md)
