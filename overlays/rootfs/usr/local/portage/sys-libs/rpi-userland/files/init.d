#!/sbin/runscript

PIDFILE=/var/run/vcfiled.pid

depend() {
    need localmount
}

start() {
    ebegin "Starting vcfiled"
    start-stop-daemon --start --quiet --background \
        --pidfile ${PIDFILE} --make-pidfile \
        --exec /sbin/vcfiled -- --foreground
    eend $?
}

stop() {
    ebegin "Stopping vfiled"
    start-stop-daemon --stop --quiet \
        --pidfile ${PIDFILE}
    eend $?
}
