## The VoidBang Linux iso image source files

#### Examples

Build an x86 live image with runit and keyboard set to 'fr':

    # ./mklive.sh -k fr

Build an x86 live image with systemd and some optional packages:

    # ./mklive.sh -b base-system-systemd -p 'vim rtorrent'

See the usage output for more information :-)
