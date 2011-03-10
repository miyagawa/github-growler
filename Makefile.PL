use inc::Module::Install;

name "github-growler";
all_from "github-growler.pl";
install_script "github-growler.pl";

requires 'Config::IniFiles';
requires 'Cocoa::Growl';
requires 'Cocoa::EventLoop';
requires 'AnyEvent::Impl::Cocoa';
requires 'AnyEvent::HTTP';
requires 'Web::Scraper';
requires 'XML::LibXML';

WriteAll;
