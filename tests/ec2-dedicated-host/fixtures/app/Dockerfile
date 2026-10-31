# tests/ec2-dedicated-host/fixtures/app/Dockerfile
# / -> fixture-ok; /health only when HEALTHY=1; /cgi-bin/boom -> the app's own 500 (busybox CGI passes an
# "HTTP/..." status line through as-is).
FROM busybox:1.36
ARG HEALTHY=1
RUN mkdir -p /www/cgi-bin && echo fixture-ok > /www/index.html \
 && printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.0 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\napp-error\n"' > /www/cgi-bin/boom \
 && chmod 755 /www/cgi-bin/boom \
 && if [ "$HEALTHY" = 1 ]; then echo ok > /www/health; fi
EXPOSE 3000
CMD ["httpd", "-f", "-p", "3000", "-h", "/www"]
