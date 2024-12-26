program pumpcontroller;

{$macro on}
{$inline on}

uses
  wificonnect2, ap_login,
  webserver,
  esp_err, portmacro, esp_log,
  rtc_wdt, aj_sr04m_unit, flowmeter,
  projdefs, timer, timer_types,
  queue, dataunit,
  semphr, settingsmanager, hardwareconfig, runstateunit,
  timeunit, timeralarm, task;

var
  levelSensor: TAJ_SR04M;
  flowsensor: TPulseFlowmeter;
  level: integer;
  flow: single;
  count, oldcount: uint16;
  dataCount: integer;
  runState: TRunStateMachine;
  alarm: TTimerAlarm;

// ~/fpc/xtensa/esp-idf-4.4.7/components/esptool_py/esptool/esptool.py -p /dev/ttyUSB0 -b 921600 -c auto write_flash 0x10000 pumpcontroller.bin

const
  maxCount = 15; //60;  // Save data every minute

begin
  rtc_wdt_disable; // In case WDT was initialized by bootloader
  esp_log_level_set('*', ESP_LOG_WARN);

  tmpSSID := '';
  tmpPassword := '';
  repeat
    connectWifiAP(tmpSSID, tmpPassword);
    if not stationConnected then
    begin
      writeln('Could not connect to wifi, starting local access point');
      stopWifi;
      // Get list of access points for APserver
      wifi_scan;

      reconnect := false;
      createWifiAP('selectSSID', '');
      start_APserver;
      while not reconnect do
        vTaskDelay(100);

      writeln('Attempting reconnecting to wifi');
      stop_APserver;
      stopWifi;
    end;
  until stationConnected;
  //start_webserver;

  oldcount := 0;
  dataIndex := 0;
  dataCount := 0;
  level := 0;
  flow := 0;
  runState.init();

  dataSem := xSemaphoreCreateMutex;
  xSemaphoreGive(dataSem);

  alarm.initTimerAlarm(TIMER_GROUP_0, TIMER_0, TIMER_AUTORELOAD_EN, 1, xTaskGetCurrentTaskHandle());

  if loadSettings() = ESP_FAIL then
  begin
    writeln('Using default settings');
    // Set default values
    settings.LLstart      := 750; // mm
    settings.HLstop       := 500; // mm
    settings.restartDelay := 15;  // minutes
    settings.LFstop       := 10;  // L/min
    settings.startDeadTime:= 15;  // s
  end;

  // Uses NTP, so start after WiFi is connected
  writeln('Init time');
  initTime;

  writeln('Starting web server...');
  start_webserver;

  writeln('init level sensor');
  levelSensor.init(levelSensorUart, levelSensorTxPin, levelSensorRxPin);

  writeln('init pulse counter');
  flowsensor.init(flowSensorCounterUnit, flowSensorPulsePin);
  writeln('Done init'#10);

  // Loop runs every 1 second
  repeat
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY); // Clear notification count

    count := flowsensor.getReading;

    if levelSensor.readDistance(currentLevel) then
    begin
      write('Level = ', currentLevel:4, 'mm   ');
      level := level + currentLevel;
    end
    else // Communication error, assume same reading as disconnected sensor
      currentLevel := 6016;

    if count < uint16($FFFF) then
    begin
      //writeln('Count = ', count);
      currentFlow := (count - oldcount) / 27; // Datasheet factor: 6.6;
      writeln('flow = ', currentFlow:1:2, ' L/min');
      oldcount := count;
      flow := flow + currentFlow;
    end
    else
    begin  // Unlikely, but then what to do?
      currentFlow := 0;
      writeln('Error reading flowsensor.');
    end;

    if dataCount >= maxCount-1 then
    begin
      level := level div maxCount;
      flow := flow / maxCount;

      xSemaphoreTake(dataSem, portMAX_DELAY);
      levels[dataIndex] := level;
      flows[dataIndex] := round(flow*10); // convert to dL/min, then it is already scaled for plotting
      inc(dataIndex);
      if dataIndex > high(levels) then
        dataIndex := 0;
      xSemaphoreGive(dataSem);

      // Construct CSV data for log file
      // Format: timestamp,level[mm from top],flow[L/min avg]
      logToFile(level, flow);

      dataCount := 0;
      level := 0;
      flow := 0;
    end
    else
      inc(dataCount);

    runState.update(currentLevel, currentFlow);
  until false;
end.
