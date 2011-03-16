#!/bin/sh
VERSION=`perl -lne '/qv\("(v[\d\.]+)"\)/ and print $1' github-growler.pl`
echo "Building Github Growler $VERSION"

rm -rf "Github Growler.app"

# bundle extra libraries into extlib
/usr/bin/perl -S cpanm -L extlib --notest --installdeps .

# Build .app
platypus -a 'Github Growler' \
  -o None \
  -u "Tatsuhiko Miyagawa" \
  -p /usr/bin/perl \
  -s '????' \
  -i appIcon.icns \
  -I net.bulknews.GithubGrowler \
  -N "APP_BUNDLER=Platypus-4.0" \
  -f data/octocat.png \
  -f extlib \
  -c github-growler.pl \
  -V $VERSION ./Github\ Growler.app
echo

# Build.zip
zip -r Github-Growler-$VERSION.zip "Github Growler.app" > /dev/null

echo "Github-Growler-$VERSION.zip created"

