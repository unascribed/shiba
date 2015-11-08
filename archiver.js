piepan.On("message", function(e) {
	var msg = e.Message;
	if (msg.indexOf('recall ') == 0) {
		console.log(e.Sender.Name+": "+msg);
		var split = msg.split(" ");
		for (var i = 1; i < split.length; i++) {
			var filename = split[i];
			if (filename.indexOf("/") >= 0) {
				piepan.Self.Channel.Send('No', false);
				continue;
			}
			var type;
			if (/jpg$/.exec(filename)) {
				type = "JPEG";
			} else if (/png$/.exec(filename)) {
				type = "PNG"
			} else {
				piepan.Self.Channel.Send('Unknown file extension', false);
				continue;
			}
			piepan.Process.New(function(code, stdout) {
				if (code) {
					piepan.Self.Channel.Send('<img src="data:image/'+type+';base64,'+stdout+'"/>', false);
				} else {
					piepan.Self.Channel.Send('Failed to recall image', false);
				}
			}, "base64", "imgs/"+filename);
		}
	}
	var imgMatcher = new RegExp('<img src="(.*?)"/>', 'g');
	var matches = imgMatcher.exec(msg);
	var i = 1;
	try {
		while (matches) {
			if (i >= 50) {
				console.error("Maximum iterations exceeded")
				break;
			}
			var s = matches[1];
			var idx = s.indexOf(',');
			var base = s.substring(0, idx);
			var b64 = decodeURIComponent(s.substring(idx+1)).replace(/ /g, '');
			var filename;
			var nm = e.Sender.Name.replace(/\//g, "_").replace("♦", "").replace("♢", "");
			if (base == "data:image/PNG;base64") {
				filename = "imgs/"+nm+"-"+Date.now()+"-"+i+".png";
			} else if (base == "data:image/JPEG;base64") {
				filename = "imgs/"+nm+"-"+Date.now()+"-"+i+".jpg";
			} else {
				console.warn("Unknown img content "+base)
				continue;
			}
			if (b64.indexOf("'") >= 0 || b64.indexOf("\\") >= 0 || b64.indexOf("`") >= 0 || b64.indexOf("$") >= 0) {
				console.warn(b64);
				console.warn(e.Sender.Name+" attempted to perform shell injection");
				piepan.Self.Channel.Send("Shell injection detected. Operator alerted.", false);
				return;
			}
			piepan.Process.New(function(code) {
				if (code) {
					piepan.Self.Channel.Send("<sub>Image saved as "+filename.replace("imgs/", "")+"</sub>", false);
				} else {
					piepan.Self.Channel.Send("<sub>Failed to save image</sub>", false);
				}
			}, "bash", "-c", "echo '"+b64+"' | base64 -d > "+filename);
			matches = imgMatcher.exec(msg);
			i++;
		}
	} catch (e) {
		console.error(e);
		piepan.Self.Channel.Send("Error: "+e.message, false);
	}
});