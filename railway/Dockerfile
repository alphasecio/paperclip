FROM ghcr.io/paperclipai/paperclip:latest
RUN mv /usr/local/bin/docker-entrypoint.sh /usr/local/bin/upstream-entrypoint.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENV PAPERCLIP_DEPLOYMENT_EXPOSURE=public
