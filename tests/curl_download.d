/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "Curl download - a simple example of using std.net.curl with Photon",
	"license": "BOOST",
	"name": "curl_download"
}
+/
import std.algorithm, std.net.curl, std.string, std.datetime.stopwatch, std.range, std.stdio;
import std.file : remove;
import core.thread;
import photon;

// try your own urls
immutable urls = [
	"https://mirror.yandex.ru/debian/doc/FAQ/debian-faq.en.html.tar.gz",
	"https://mirror.yandex.ru/debian/doc/FAQ/debian-faq.en.pdf.gz",
	"https://mirror.yandex.ru/debian/doc/FAQ/debian-faq.en.ps.gz",
	"https://mirror.yandex.ru/debian/doc/FAQ/debian-faq.en.txt.gz",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/accumulo-monitor-1.8.1-9.fc28.noarch.rpm",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/accumulo-native-1.8.1-9.fc28.x86_64.rpm",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/accumulo-server-base-1.8.1-9.fc28.noarch.rpm",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/accumulo-shell-1.8.1-9.fc28.x86_64.rpm",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/accumulo-tracer-1.8.1-9.fc28.noarch.rpm",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/accumulo-tserver-1.8.1-9.fc28.noarch.rpm",
	"http://www.v6.mirror.yandex.ru/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/a/acegisecurity-1.0.7-9.fc28.noarch.rpm"
];

void main(){
	initPhoton();
	void spawnDownload(string url, string file) {
		go(() => download(url, file));
	}
	Thread threadDownload(string url, string file) {
		auto t = new Thread(() => download(url, file));
		t.start();
		return t;
	}
	StopWatch sw;
	sw.reset();
	sw.start();
	foreach(url; urls) {
		download(url, url.split('/').back);
	}
	sw.stop();
	writefln("Sequentially: %s ms", sw.peek.total!"msecs");
	
	foreach(url; urls) {
		remove(url.split('/').back);
	}

	sw.reset();
	sw.start();
	urls
		.map!(url => threadDownload(url, url.split('/').back))
		.array
		.each!(t => t.join());
	sw.stop();
	writefln("Threads: %s ms", sw.peek.total!"msecs");
	
	foreach(url; urls) {
		remove(url.split('/').back);
	}

	sw.reset();
	sw.start();
	foreach(url; urls) {
		spawnDownload(url, url.split('/').back);
	}
	runScheduler();
	sw.stop();
	writefln("Concurrently: %s ms", sw.peek.total!"msecs");
	
}