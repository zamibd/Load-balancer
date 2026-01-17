# HAProxy with Lua support for tenant validation
FROM haproxy:3.3.1-alpine

# Install required packages for Lua HTTP client and utilities
RUN apk add --no-cache \
    lua5.4 \
    lua5.4-socket \
    ca-certificates \
    curl

# Create necessary directories
RUN mkdir -p /usr/local/etc/haproxy/certs \
    && mkdir -p /usr/local/etc/haproxy/lua \
    && mkdir -p /var/run/haproxy

# Set proper permissions
RUN chown -R haproxy:haproxy /var/run/haproxy

# Copy configuration (done via volumes in docker-compose, but set defaults)
COPY haproxy/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

# Expose ports
EXPOSE 853 8404

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD echo 'quit' | nc -w 1 127.0.0.1 8404 || exit 1

# Run HAProxy
CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
