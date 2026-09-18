import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const versionServiceBase =
    'https://holiday-resort-owner-api.holiday-resort-mrx.workers.dev/';

enum UpdateState { upToDate, optional, mandatory }

UpdateState classifyBuild(int installed, int latest, int minimum) {
  if (installed < minimum) return UpdateState.mandatory;
  if (installed < latest) return UpdateState.optional;
  return UpdateState.upToDate;
}

UpdateState classifyOfflineBuild(int installed, VersionPolicy? cached) =>
    cached != null && installed < cached.minimumBuild
        ? UpdateState.mandatory
        : UpdateState.upToDate;

class VersionPolicy {
  const VersionPolicy({required this.latestBuild, required this.minimumBuild,
    required this.updateUrl, required this.releaseNotes});
  final int latestBuild, minimumBuild;
  final String updateUrl, releaseNotes;
  factory VersionPolicy.fromJson(Map<String, dynamic> json) => VersionPolicy(
    latestBuild: (json['latestBuild'] as num).toInt(),
    minimumBuild: (json['minimumSupportedBuild'] as num).toInt(),
    updateUrl: json['updateUrl'] as String,
    releaseNotes: json['releaseNotes']?.toString() ?? '',
  );
  Map<String, dynamic> toJson() => {'latestBuild':latestBuild,
    'minimumSupportedBuild':minimumBuild,'updateUrl':updateUrl,
    'releaseNotes':releaseNotes};
}

class VersionService {
  VersionService({http.Client? client}) : _client=client ?? http.Client();
  final http.Client _client;
  Future<VersionPolicy> fetch(String app) async {
    Object? last;
    for(var attempt=0;attempt<2;attempt++) {
      try {
        final response=await _client.get(Uri.parse('${versionServiceBase}app-version?app=$app'))
            .timeout(const Duration(seconds: 4));
        if(response.statusCode!=200) throw StateError('HTTP ${response.statusCode}');
        return VersionPolicy.fromJson(jsonDecode(response.body) as Map<String,dynamic>);
      } catch(error) { last=error; if(attempt==0) await Future<void>.delayed(const Duration(milliseconds: 350)); }
    }
    throw StateError('Version service unavailable: $last');
  }
}

class AppVersionGate extends StatefulWidget {
  const AppVersionGate({super.key,required this.app,required this.child,this.service});
  final String app; final Widget child; final VersionService? service;
  @override State<AppVersionGate> createState()=>_AppVersionGateState();
}

class _AppVersionGateState extends State<AppVersionGate> {
  static const _cache=MethodChannel('holiday_resort/version_cache');
  VersionPolicy? policy; UpdateState? state; bool ready=false;
  String get _cacheKey=>'version_policy_${widget.app}';
  @override void initState(){super.initState();_check();}
  Future<void> _check() async {
    final info=await PackageInfo.fromPlatform();
    final installed=int.tryParse(info.buildNumber)??0;
    try {
      final fresh=await (widget.service??VersionService()).fetch(widget.app);
      await _cache.invokeMethod<void>('write',{'key':_cacheKey,'value':jsonEncode(fresh.toJson())});
      policy=fresh;state=classifyBuild(installed,fresh.latestBuild,fresh.minimumBuild);
    } catch (_) {
      String? cached;
      try { cached=await _cache.invokeMethod<String>('read',{'key':_cacheKey}); } catch (_) {}
      if(cached!=null) {
        try { final value=VersionPolicy.fromJson(jsonDecode(cached));
          state=classifyOfflineBuild(installed,value);
          if(state==UpdateState.mandatory) policy=value;
        } catch (_) {}
      }
      state??=classifyOfflineBuild(installed,null);
    }
    if(!mounted)return;setState(()=>ready=true);
    if(state==UpdateState.optional) WidgetsBinding.instance.addPostFrameCallback((_)=>_optional());
  }
  Future<void> _open() async {final uri=Uri.tryParse(policy?.updateUrl??'');
    if(uri!=null&&uri.isScheme('https')) await launchUrl(uri,mode:LaunchMode.externalApplication);}
  Future<void> _optional()=>showDialog<void>(context:context,builder:(context)=>AlertDialog(
    title:const Text('Update available'),content:Text(policy!.releaseNotes.isEmpty?'A newer version is available.':policy!.releaseNotes),
    actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('LATER')),
      FilledButton(onPressed:_open,child:const Text('UPDATE'))]));
  @override Widget build(BuildContext context){
    if(!ready)return const MaterialApp(debugShowCheckedModeBanner:false,home:Scaffold(body:Center(child:CircularProgressIndicator())));
    if(state!=UpdateState.mandatory)return widget.child;
    return MaterialApp(debugShowCheckedModeBanner:false,home:Scaffold(body:SafeArea(child:Center(child:Padding(
      padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Icon(Icons.system_update_alt,size:72,color:Color(0xff087cff)),const SizedBox(height:20),
        const Text('Holiday Resort',style:TextStyle(fontSize:28,fontWeight:FontWeight.bold,color:Color(0xff061379))),
        const SizedBox(height:12),const Text('Update Required',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
        const SizedBox(height:8),const Text('A new version is required to continue.',textAlign:TextAlign.center),
        const SizedBox(height:24),FilledButton.icon(onPressed:_open,icon:const Icon(Icons.download),label:const Text('UPDATE NOW'))
      ]))))));
  }
}
