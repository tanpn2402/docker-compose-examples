FROM tomcat:8.5.89

ARG UID=1000
ARG GID=1000

RUN groupadd -g $GID tomcat && useradd -u $UID -g tomcat tomcat
RUN mkdir -p /usr/local/tomcat/webapps /ttl/config/winvest /ttllogs/mobile && \
    chown -R tomcat:tomcat /usr/local/tomcat /ttl /ttllogs

USER tomcat

WORKDIR /usr/local/tomcat

CMD ["catalina.sh", "run"]

