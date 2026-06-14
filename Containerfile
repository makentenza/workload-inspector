FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y nginx procps-ng && \
    microdnf clean all && \
    rm -rf /var/cache/yum

COPY nginx.conf /etc/nginx/nginx.conf
COPY static/ /usr/share/nginx/html/
COPY probe.sh /opt/workload-inspector/probe.sh
COPY entrypoint.sh /opt/workload-inspector/entrypoint.sh

RUN chmod +x /opt/workload-inspector/*.sh && \
    mkdir -p /usr/share/nginx/html/data && \
    chgrp -R 0 /var/lib/nginx /var/log/nginx /run /usr/share/nginx/html/data && \
    chmod -R g=u /var/lib/nginx /var/log/nginx /run /usr/share/nginx/html/data

EXPOSE 8080

USER 1001

ENTRYPOINT ["/opt/workload-inspector/entrypoint.sh"]
