import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/system.dart';
import 'package:path/path.dart' as p;
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop
    ? Proxy(
        ownershipFile: appPath.homeDirPath.then(
          (home) => File(p.join(home, '.system-proxy-ownership.json')),
        ),
      )
    : null;
