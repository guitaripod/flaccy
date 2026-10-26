FROM rust:alpine AS build
RUN apk add --no-cache build-base
WORKDIR /src
COPY . .
RUN cargo build --release --locked -p flaccy-server

FROM alpine:3.22
RUN apk add --no-cache ffmpeg \
 && adduser -D -u 1000 flaccy \
 && mkdir -p /data /music \
 && chown flaccy:flaccy /data
COPY --from=build /src/target/release/flaccy-server /usr/local/bin/flaccy-server
COPY server/packaging/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
ENV FLACCY_SERVER_CONFIG=/data/config.toml
USER flaccy
VOLUME /data
EXPOSE 4545
HEALTHCHECK --interval=30s --timeout=8s --start-period=30s --retries=3 CMD ["flaccy-server", "healthcheck"]
ENTRYPOINT ["entrypoint.sh"]
CMD ["serve"]
