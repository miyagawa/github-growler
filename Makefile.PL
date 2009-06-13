use inc::Module::Install;

name "github-growler";
all_from "github-growler.pl";
install_script "github-growler.pl";

requires 'App::Cache';
requires 'Config::IniFiles';
requires 'Mac::Growl';
requires 'LWP::Simple';
requires 'URI';
requires 'XML::Feed';
requires 'Web::Scraper';

WriteAll;
