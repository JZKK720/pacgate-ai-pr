# Wrapper image around the published Pacgate sandbox tooling image.
#
# WHY IT EXISTS (plan 025, live E2E 2026-10-05): the `local` sandbox backend
# (SANDBOX_BACKEND=local, the compose path this repo uses) requires the sandbox
# image to RUN an exec daemon — upstream `microvm-agent` (an HTTP server on
# :8080 exposing POST /exec, /read, /write; bundled in the qm package under
# templates/aws/microvm-agent/agent.mjs). The published
# `pacgate-sandboxes@52e867fc…` image is a TOOLING image: its default command
# is an idle sleep loop and nothing listens on 8080, so every exec fails with
# "exec daemon never became reachable" while the container stays Up.
#
# This wrapper only adds the daemon + the CMD; all tooling (pacgate-qm,
# firecrawl, markitdown, pandoc, fonts) is inherited from the base.
#
# Build: docker buildx build --platform linux/amd64 --provenance=false \
#          --load -t qm-pacgate-sandbox-local:latest .
# (provenance=false for a stable local digest, matching the repo's publish
# convention; the compose pin references this TAG, not a digest, because this
# is a machine-local build artifact refreshed with the qm-pacgate tree.)

FROM ghcr.io/jzkk720/pacgate-sandboxes@sha256:52e867fcb195f07c5ff32fc78e8ac3f35d000ebd5f34d6c8d792c602f6eae65b

COPY microvm-agent.mjs /opt/microvm-agent/agent.mjs

ENV HOME=/root
WORKDIR /root

# The base CMD is an idle sleep loop; replace with the exec daemon. The core's
# waitDaemon polls GET http://<container>:8080/health for up to 30 s at spawn.
ENTRYPOINT []
CMD ["node", "/opt/microvm-agent/agent.mjs"]