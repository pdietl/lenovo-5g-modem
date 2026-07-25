CC      ?= cc
CFLAGS  ?= -O2 -Wall
PREFIX  ?= /usr/local
SYSCONF ?= /etc

HOOK = 17cb:0308

all: foxconn-fcc-unlock foxconn-fcc-relock

foxconn-fcc-unlock: foxconn-fcc-unlock.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

foxconn-fcc-relock: foxconn-fcc-relock.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

# The hook must land in sysconfdir, not libdir: ModemManager searches
# sysconfdir first, which is how this overrides Lenovo's hook of the same name.
install: foxconn-fcc-unlock
	install -D -m 0755 foxconn-fcc-unlock \
		$(DESTDIR)$(PREFIX)/sbin/foxconn-fcc-unlock
	install -D -m 0755 './$(HOOK)' \
		'$(DESTDIR)$(SYSCONF)/ModemManager/fcc-unlock.d/$(HOOK)'
	install -D -m 0644 foxconn-fcc-unlock.c \
		$(DESTDIR)$(PREFIX)/src/foxconn-fcc-unlock/foxconn-fcc-unlock.c
	install -D -m 0644 foxconn-fcc-relock.c \
		$(DESTDIR)$(PREFIX)/src/foxconn-fcc-unlock/foxconn-fcc-relock.c

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/sbin/foxconn-fcc-unlock
	rm -f '$(DESTDIR)$(SYSCONF)/ModemManager/fcc-unlock.d/$(HOOK)'
	rm -rf $(DESTDIR)$(PREFIX)/src/foxconn-fcc-unlock

clean:
	rm -f foxconn-fcc-unlock foxconn-fcc-relock

.PHONY: all install uninstall clean
