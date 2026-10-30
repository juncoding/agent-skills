# tests/ec2-dedicated-host/fixtures/app/Dockerfile
FROM busybox:1.36
ARG HEALTHY=1
RUN mkdir -p /www && echo fixture-ok > /www/index.html && if [ "$HEALTHY" = 1 ]; then echo ok > /www/health; fi
EXPOSE 3000
CMD ["httpd", "-f", "-p", "3000", "-h", "/www"]
