# GScale Mobile App

## Abstract
`gscale-mobile-app` is the operator-facing Flutter client of the GScale system. It is designed for mobile-first warehouse execution, where the phone or tablet becomes the primary control surface for:

- ERP setup confirmation,
- default warehouse selection,
- item search,
- batch start and stop,
- live process monitoring,
- archive inspection.

This repository is one member of a three-repository architecture:

- [`gscale-platform`](https://github.com/accord-erp-automation/gscale-platform): runtime coordination, mobile API, scale worker, simulator, and print-request flow.
- [`gscale-erp-read`](https://github.com/accord-erp-automation/gscale-erp-read): ERP-side read-only catalog service.
- [`gscale-mobile-app`](https://github.com/WIKKIwk/gscale-mobile-app): the repository documented here.

If the other repositories execute the workflow, this one is where the operator experiences it.

## Position in the Overall System

```text
Operator
   |
   v
gscale-mobile-app
   |
   v
gscale-platform/mobileapi
   |
   +---------------------> gscale-erp-read
   |
   +---------------------> scale worker / bridge state / Zebra flow
```

The app does not talk to ERP directly. It talks to `mobileapi`, which in turn coordinates ERP setup, catalog lookup, batch lifecycle, and runtime state.

## Design Goals

This client was designed with four priorities:

- reduce operator friction,
- centralize the operational workflow into one interface,
- provide live feedback during batch execution,
- make the runtime understandable without exposing infrastructure details.

The application therefore acts less like a generic admin panel and more like a focused field workflow console.

## Major Features

### Server Discovery and Selection
The app is designed to discover or reconnect to the active `mobileapi` instance and maintain a usable server reference for later sessions.

### ERP Configuration View
The app surfaces whether:

- ERP write access is configured,
- the read service is connected,
- a default warehouse has been set,
- batch actions are available.

### Item Selection
The item picker queries `mobileapi`, which delegates catalog behavior to `gscale-erp-read` or ERP-backed fallback logic. The item picker therefore reflects the search behavior and warehouse-filtering rules defined outside this repository.

### Warehouse Selection
The app supports both:

- manual warehouse selection,
- default warehouse mode.

In default warehouse mode, the item list is expected to be constrained by backend policy. This repository assumes that `gscale-platform` and `gscale-erp-read` enforce that contract correctly.

### Batch Control
The app can:

- start a batch,
- stop a batch,
- display live scale and printer state,
- expose archive summaries.

This makes it the preferred operator interface when the system is used without Telegram.

## Dependency on Companion Repositories

### Dependency on `gscale-platform`
This repository relies on `gscale-platform` for all operational endpoints. Important examples include:

- `/v1/mobile/handshake`
- `/v1/mobile/setup/status`
- `/v1/mobile/items`
- `/v1/mobile/items/{item_code}/warehouses`
- `/v1/mobile/warehouses`
- `/v1/mobile/batch/start`
- `/v1/mobile/batch/stop`
- `/v1/mobile/monitor/state`
- `/v1/mobile/archive`

The app is therefore tightly aligned with the API contract implemented in `gscale-platform`.

### Indirect Dependency on `gscale-erp-read`
Although the app does not usually call `gscale-erp-read` directly, the user-visible behavior of:

- item search,
- default warehouse item filtering,
- item-to-warehouse narrowing,

depends on how `gscale-platform` and `gscale-erp-read` cooperate. This repository should therefore be read as the presentation layer of a deeper catalog contract.

## User Workflow Model

The expected operator flow is:

1. connect to the correct backend server,
2. confirm ERP configuration,
3. choose default warehouse mode or manual mode,
4. select an item,
5. start a batch,
6. watch live scale and print progress,
7. inspect archive history when needed.

This order matters. The app is not only a screen collection; it expresses the intended transaction sequence of the system.

## Development and Running

This repository is a Flutter application. Typical local development commands depend on your target platform, but conceptually the app expects one environment variable:

```bash
--dart-define=API_BASE_URL=http://127.0.0.1:39117
```

In the wider system, that backend is usually started from the `gscale-platform` repository.

## Documentation Boundary

This README intentionally does not describe:

- Zebra protocol internals,
- ERP draft creation payloads,
- bridge-state semantics,
- simulator lifecycle details.

Those belong to `gscale-platform`. Likewise, ERP catalog service internals belong to `gscale-erp-read`.

## Recommended Companion Reading

For a complete understanding of the system behind this client, read:

1. [`gscale-platform`](https://github.com/accord-erp-automation/gscale-platform)
2. [`gscale-erp-read`](https://github.com/accord-erp-automation/gscale-erp-read)

Those repositories explain the execution engine and the read-model service that this app depends on.
