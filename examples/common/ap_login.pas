unit ap_login;

interface

uses
  esp_http_server;

var
  tmpSSID: string[32];
  reconnect: boolean = false;
  tmpPassword: string[64];

procedure wifi_scan;
function start_APserver: Thttpd_handle;
procedure stop_APserver;

implementation

uses
  esp_err, http_parser,
  esp_wifi, esp_wifi_types, esp_event;

const
  APnum = 10;

var
  server: Thttpd_handle;
  APlist: array[0..APnum-1] of string[33];

const
  apSelectPage1 =
  '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">'+
  '<style>body {font-family:Arial,Helvetica,sans-serif;}'+
  'form {border: 4px solid #f1f1f1;} select[type=ssid], input[type=password] {'+
  'width:100%; padding:12px 20px; margin:8px 0; display:inline-block;'+
  'border:1px solid #ccc; box-sizing:border-box;}'+
  'button {background-color:#04AA6D; color:white; padding:14px 20px; '+
  'margin:8px 0; border:none; cursor:pointer; width:100%;}'+
  'button:hover{opacity:0.8;} .container{padding:16px;}'+
  'span.pwd{float:right; padding-top:16px;}'+
  '@media screen and (max-width:300px) {span.pwd{display:block;float: none;}}'+
  '</style></head><body><h2>Connect to WiFi</h2>'+
  '<form action="/login" method="post">'+
  '<div class="container">'+
  '<label for="SSID"><b>Select SSID</b></label>'+
  '<select type="ssid" name="SSID" required>';
//  '<option value="DVD">DVD</option>'+

  apSelectPage2 =
  '</select><br>'+
  '<label for="pwd"><b>Password</b></label>'+
  '<input type="password" placeholder="Enter Password" name="pwd" required>'+
  '<button type="submit">Login</button>'+
  '</div></form></body></html>';

apSelectedMsg = 'Stopping local access point and connecting to'#13#10+
                 'SSID: ';
apFinalMsg    = #13#10'It may take a short while before the new connection is available.';

procedure wifi_scan;
var
  cfg: Twifi_init_config;
  ap_info: array[0..APnum-1] of Twifi_ap_record;
  ap_info_len: uint16 = APnum;
  i: integer;
begin
  EspErrorCheck(esp_event_loop_create_default());
  WIFI_INIT_CONFIG_DEFAULT(cfg);
  EspErrorCheck(esp_wifi_init(@cfg));
  EspErrorCheck(esp_wifi_set_mode(WIFI_MODE_STA));
  EspErrorCheck(esp_wifi_start());

  // Start scan with default settings, block until done
  EspErrorCheck(esp_wifi_scan_start(nil, true));

  // Get collected records
  ap_info_len := length(ap_info);
  EspErrorCheck(esp_wifi_scan_get_ap_records(@ap_info_len, @ap_info[0]));
  EspErrorCheck(esp_wifi_scan_get_ap_num(@ap_info_len));

  // Copy SSIDs to APlist
  if ap_info_len > 0 then
  begin
    for i := 0 to ap_info_len-1 do
    begin
      APlist[i] := PChar(@(ap_info[i].ssid[0]));
      writeln('AP #', i, ': ', APlist[i]);
    end;

    // Set remainder of list to empty strings
    if ap_info_len < APnum then
      for i := ap_info_len to APnum-1 do
        APlist[i] := '';
  end
  else
    writeln('No AP records returned.');

  esp_wifi_stop();
  esp_wifi_deinit();
end;

function get_handler(req: Phttpd_req): Tesp_err;
var
  s: string[64];
  i: integer;
begin
  httpd_resp_send_chunk(req, apSelectPage1, length(apSelectPage1));

  i := 0;
  while (i < APnum) and (APlist[i] <> '') do
  begin
    s := '<option value="'+APlist[i]+'">'+APlist[i]+'</option>';
    httpd_resp_send_chunk(req, @s[1], length(s));
    inc(i);
  end;

  httpd_resp_send_chunk(req, apSelectPage2, length(apSelectPage2));
  httpd_resp_send_chunk(req, nil, 0);

  result := ESP_OK;
end;

// Handler should receive content: SSID=ssid_name&pwd=password
function post_handler(req: Phttpd_req): Tesp_err;
var
  size, ret: integer;
  buf: array[0..180] of char;
begin
  reconnect := false;
  FillChar(buf, SizeOf(buf), #0);
  size := length(buf);
  ret := httpd_req_recv(req, @buf, size);
  if ret <= 0 then
  begin
    if ret = HTTPD_SOCK_ERR_TIMEOUT then
    {$ifdef CPULX6}
      httpd_resp_send_err(req, HTTPD_408_REQ_TIMEOUT, nil);
    {$else}
      httpd_resp_send_408(req);
    {$endif}
    exit(ESP_FAIL);
  end;

  FillChar(tmpSSID[1], high(tmpSSID), #0);
  if httpd_query_key_value(@buf, 'SSID'#0, @tmpSSID[1], high(tmpSSID)) = ESP_OK then
  begin
    reconnect := true;
    SetLength(tmpSSID, length(PChar(@tmpSSID[1])));
  end
  else
    writeln('Error reading SSID');

  if reconnect then
  begin
    FillChar(tmpPassword[1], high(tmpPassword), #0);
    if httpd_query_key_value(@buf, 'pwd'#0, @tmpPassword[1], high(tmpPassword)) = ESP_OK then
      SetLength(tmpPassword, length(PChar(@tmpPassword[1])))
    else
    begin
      writeln('Error reading pwd');
      reconnect := false;
    end;
  end;

  Result := httpd_resp_send_chunk(req, @apSelectedMsg[1], length(apSelectedMsg));
  Result := httpd_resp_send_chunk(req, @tmpSSID[1], length(tmpSSID));
  Result := httpd_resp_send_chunk(req, @apFinalMsg[1], length(apFinalMsg));
  Result := httpd_resp_send_chunk(req, nil, 0);
end;

function start_APserver: Thttpd_handle;
var
  config: Thttpd_config;
  getUriHandlerConfig: Thttpd_uri;
  postUriHandlerConfig: Thttpd_uri;
begin
  config := HTTPD_DEFAULT_CONFIG();
  with getUriHandlerConfig do
  begin
    uri       := '/';
    method    := HTTP_GET;
    handler   := @get_handler;
    user_ctx  := nil;
  end;

  with postUriHandlerConfig do
  begin
    uri       := '/login';
    method    := HTTP_POST;
    handler   := @post_handler;
    user_ctx  := nil;
  end;

  if (httpd_start(@server, @config) = ESP_OK) then
  begin
    httpd_register_uri_handler(server, @getUriHandlerConfig);
    httpd_register_uri_handler(server, @postUriHandlerConfig);
    result := server;
  end
  else
  begin
    result := nil;
    writeln('### Failed to start httpd');
  end;
end;

procedure stop_APserver;
begin
  if Assigned(server) then
  begin
    httpd_unregister_uri(server, '/');
    httpd_unregister_uri(server, '/login');
    httpd_stop(server);
    server := nil;
  end;
end;

end.
