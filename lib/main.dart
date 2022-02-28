import 'package:window_manager/window_manager.dart';
import 'package:system_theme/system_theme.dart';
import 'package:http/http.dart' as http;
import 'package:windows_taskbar/windows_taskbar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:retry/retry.dart';

import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';

Directory documentsDirectory = Directory("");

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WindowManager.instance.ensureInitialized();

  windowManager.waitUntilReadyToShow().then((_) async {
    await windowManager.setTitleBarStyle('hidden');
    await windowManager.setSize(const Size(800, 600));
    await windowManager.setResizable(false);
    await windowManager.center();
    await windowManager.show();
    await windowManager.setSkipTaskbar(false);
  });

  documentsDirectory = await getApplicationDocumentsDirectory();
  WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);

  runApp(const KitsuneScraper());
}

class KitsuneScraper extends StatelessWidget {
  const KitsuneScraper({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return FluentApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        accentColor: SystemTheme.accentInstance.accent.toAccentColor(),
        brightness: Brightness.dark,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      title: 'Kitsune Scraper',
      initialRoute: '/',
      routes: {'/': (_) => const MainPage()},
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({Key? key}) : super(key: key);

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WindowListener {
  static const values = [
    {'name': 'Kemono', 'url': 'https://kemono.party'},
    {'name': 'Coomer', 'url': 'https://coomer.party'},
  ];

  String? endpoint;
  String? service;
  String? userid;
  int? page;
  int? post;

  int processed = 0;
  int downloaded = 0;

  bool isRunning = false;
  bool rateLimit = false;

  Future<List<dynamic>> processPages() async {
    List<dynamic> attachments = [];
    if (page == null) {
      List<dynamic> posts = [];
      int index = 1;
      do {
        final response = await retry(
          () => http.get(Uri.parse(
              '$endpoint/api/$service/user/$userid${index > 1 ? "?o=" + (25 * (index - 1)).toString() : ""}${page != null ? "/" + post!.toString() : ""}')),
          retryIf: (e) => e is SocketException || e is TimeoutException,
        );
        posts = jsonDecode(response.body);
        for (var post in posts) {
          attachments.addAll(post['attachments']);
        }
        index++;
      } while (posts.isNotEmpty);
    } else {
      final response = await retry(
        () => http.get(Uri.parse(
            '$endpoint/api/$service/user/$userid${page! > 1 ? "?o=" + (25 * (page! - 1)).toString() : ""}${page != null ? "/" + post!.toString() : ""}')),
        retryIf: (e) => e is SocketException || e is TimeoutException,
      );
      attachments = jsonDecode(response.body);
    }

    return attachments;
  }

  Future downloadAttachments(List attachments) async {
    for (var attachment in attachments) {
      final response = await retry(
        () async {
          final request = await HttpClient()
              .getUrl(Uri.parse('$endpoint${attachment['path']}'));
          request.headers.persistentConnection = true;
          request.headers.set(HttpHeaders.connectionHeader, "keep-alive");
          final response = await request.close();
          if (response.statusCode == 429) {
            throw Exception("429");
          }
          setState(() => rateLimit = false);
          return response;
        },
        retryIf: (e) =>
            e is SocketException ||
            e is TimeoutException ||
            e.toString() == "429",
        onRetry: (e) => setState(() => rateLimit = true),
      );

      File file = await File(
              '${documentsDirectory.path}/kitsune-scraper/$userid/${attachment['name']}')
          .create(recursive: true);
      response.pipe(file.openWrite());

      setState(() => ++downloaded);
      WindowsTaskbar.setProgress(downloaded, processed);
    }
    return;
  }

  Future<bool> runScraper() async {
    List<String> missingParameters = [];
    if (endpoint == null || endpoint!.isEmpty) {
      missingParameters.add("Endpoint");
    }
    if (userid == null || userid!.isEmpty) {
      missingParameters.add("UserID");
    }
    if (service == null || service!.isEmpty) {
      missingParameters.add("Service");
    }
    if (missingParameters.isNotEmpty) {
      String missingString = "";

      int i = 0, size = missingParameters.length;
      for (var parameter in missingParameters) {
        if (i == 0) {
          missingString += parameter;
        } else if (i == size - 1) {
          missingString += " and $parameter";
        } else {
          missingString += ", $parameter";
        }
        i++;
      }

      showDialog(
        context: context,
        builder: (_) => ContentDialog(
          title: const Text('Missing required parameters'),
          content:
              Text(missingString + ' ${size == 1 ? 'is' : 'are'} required.'),
          actions: [
            Center(
              child: FilledButton(
                child: const Text('Return'),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      );
      return false;
    }

    List attachments = await processPages();
    if (attachments.isEmpty) {
      showDialog(
        context: context,
        builder: (_) => ContentDialog(
          title: const Text('Invalid data'),
          content: const Text('No attachments found for the provided data.'),
          actions: [
            Center(
              child: FilledButton(
                child: const Text('Return'),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      );
      return false;
    }

    setState(() => processed = attachments.length);
    setState(() => isRunning = true);

    await downloadAttachments(attachments);

    setState(() => isRunning = false);
    setState(() => processed = 0);
    setState(() => downloaded = 0);

    WindowsTaskbar.setFlashTaskbarAppIcon(
      mode: TaskbarFlashMode.all | TaskbarFlashMode.timernofg,
    );
    WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);

    return true;
  }

  @override
  Widget build(BuildContext context) {
    return NavigationView(
      appBar: NavigationAppBar(
        title: const DragToMoveArea(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text("Kitsune Scraper"),
          ),
        ),
        actions: DragToMoveArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [Spacer(), WindowButtons()],
          ),
        ),
      ),
      content: ScaffoldPage.scrollable(
        //header: const PageHeader(title: Text('Forms showcase')),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: InfoLabel(
                label: 'Endpoint',
                child: Combobox<String>(
                  placeholder: const Text('Choose an endpoint'),
                  isExpanded: true,
                  items: values
                      .map((e) => ComboboxItem<String>(
                            value: e['url'],
                            child: Text(e['name']!),
                          ))
                      .toList(),
                  value: endpoint,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => endpoint = value);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(width: 375),
          ]),
          const SizedBox(height: 15),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormBox(
                onChanged: (value) => setState(() => userid = value),
                header: 'Username or UserID',
                placeholder: 'Example: 446171',
                textInputAction: TextInputAction.next,
                prefix: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 8.0),
                  child: Icon(FluentIcons.contact),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormBox(
                onChanged: (value) => setState(() => service = value),
                header: 'Service',
                placeholder: "Examples: onlyfans, patreon, fanbox, etc.",
                textInputAction: TextInputAction.next,
                prefix: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 8.0),
                  child: Icon(FluentIcons.customer_assets),
                ),
              ),
            ),
          ]),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormBox(
                onChanged: (value) =>
                    setState(() => post = int.tryParse(value)),
                header: 'Post',
                placeholder: "Leave empty to scrape the whole profile.",
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (postId) {
                  if (postId == null || postId.isEmpty) return null;
                  if (int.tryParse(postId) == null || int.parse(postId) < 1) {
                    return 'Please enter a number.';
                  }
                  return null;
                },
                textInputAction: TextInputAction.next,
                prefix: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 8.0),
                  child: Icon(FluentIcons.chat),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 95.0,
                child: TextFormBox(
                  onChanged: (value) =>
                      setState(() => page = int.tryParse(value)),
                  header: 'Page',
                  placeholder: "Leave empty to scrape the whole profile.",
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (page) {
                    if (page == null || page.isEmpty) return null;
                    if (int.tryParse(page) == null || int.parse(page) < 1) {
                      return 'Please enter a positive number.';
                    }
                    return null;
                  },
                  textInputAction: TextInputAction.next,
                  prefix: const Padding(
                    padding: EdgeInsetsDirectional.only(start: 8.0),
                    child: Icon(FluentIcons.page),
                  ),
                ),
              ),
            ),
          ]),
          Center(
            child: Column(
              children: [
                Button(
                  child: const Padding(
                    padding: EdgeInsets.only(bottom: 2),
                    child: Text(
                      "Scrape",
                      textScaleFactor: 1.10,
                    ),
                  ),
                  onPressed: isRunning ? null : runScraper,
                ),
                const SizedBox(height: 35),
                if (isRunning)
                  Card(
                    child: Column(
                      children: [
                        Center(
                          child: Text(
                              'Scraping profile for user $userid on $service'),
                        ),
                        const SizedBox(height: 4),
                        Row(children: [
                          Expanded(
                            child: ProgressBar(
                                value: ((downloaded / processed) * 100)),
                          ),
                          const SizedBox(width: 16),
                          Text(((downloaded / processed) * 100)
                                  .floor()
                                  .toString() +
                              "%"),
                          const SizedBox(width: 12),
                          Text(downloaded.toString() +
                              "/" +
                              processed.toString()),
                          const SizedBox(width: 2),
                        ]),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                              'Downloading attachments to: ${documentsDirectory.path}/kitsune-scraper/$userid/'),
                        ),
                        SizedBox(
                          height: 91,
                          child: Center(
                              child: Text(
                            rateLimit ? "Currently rate limited." : "",
                            style: const TextStyle(color: Color(0xFFD83B01)),
                          )),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      IconButton(
        onPressed: windowManager.minimize,
        icon: const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Icon(FluentIcons.chrome_minimize, size: 10),
        ),
      ),
      IconButton(
        style: ButtonStyle(
          backgroundColor: ButtonState.resolveWith(
            (Set<ButtonStates> states) {
              if (states.contains(ButtonStates.pressing)) {
                return const Color(0xFFB22A1B);
              } else if (states.contains(ButtonStates.hovering)) {
                return const Color(0xFFC42B1C);
              }
              return null;
            },
          ),
          foregroundColor: ButtonState.resolveWith(
            (Set<ButtonStates> states) {
              if (states.contains(ButtonStates.pressing) ||
                  states.contains(ButtonStates.hovering)) {
                return Colors.white;
              }
              return null;
            },
          ),
        ),
        onPressed: windowManager.close,
        icon: const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Icon(FluentIcons.chrome_close, size: 10),
        ),
      ),
      const Padding(
        padding: EdgeInsets.all(4),
      )
    ]);
  }
}
