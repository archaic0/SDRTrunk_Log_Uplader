<?php
// include_once <PDO library / SQL library>

// Set headers to strictly expect and return JSON payloads
header("Content-Type: application/json; charset=UTF-8");
header("Access-Control-Allow-Methods: POST");

// 1. Capture the raw raw input payload stream from the POST request
$rawPayload = file_get_contents("php://input");

// 2. Validate that data was actually transmitted
if (empty($rawPayload)) {
    http_response_code(400);
    echo json_encode(["status" => "error", "message" => "Empty payload received."]);
    exit();
}

// 3. Decode the raw JSON payload to ensure structured integrity
$decodedData = json_decode($rawPayload, true);
extract(json_decode($rawPayload, true), EXTR_SKIP);

if (json_last_error() !== JSON_ERROR_NONE) {
    http_response_code(400);
    echo json_encode(["status" => "error", "message" => "Malformed JSON string sequence structure."]);
    exit();
}

// 4. Verify critical identifiers are present
$ar_critical_info = array("NODE", "REGION", "DURATION_MS", "TIMESTAMP", "EVENT", "TO");

$defined_vars = array_keys(get_defined_vars());
if ($missing = array_diff($ar_critical_info, $defined_vars)) {
    error_log("[SDRTrunk Ingestion Error] Aborting payload process. Missing variables: " . implode(', ', $missing));
    http_response_code(400);
    echo json_encode(["status" => "error", "message" => "Required data elements missing: " . implode(', ', $missing)]);
    exit();
}
error_log("[INBOX_SDRLOGS] --- Event Received ---");
error_log("[INBOX_SDRLOGS] NODE: " . $NODE . " REGION: " . $REGION . " TALKGROUP: " . $TO . " Event ID: " . $EVENT_ID);
//error_log("[INBOX_SDRLOGS] Raw Content: " . $rawPayload);

// 5. Add activity data to DB

// Region to P25 system id lookup
	if($REGION == 0) { $tgSystem = 4390; }
elseif($REGION == 1) { $tgSystem = 4390; }
elseif($REGION == 2) { $tgSystem = 4390; }
elseif($REGION == 3) { $tgSystem = 4390; }
elseif($REGION == 4) { $tgSystem = 7697; }

$duration = (int)number_format(($DURATION_MS/1000),0);
$enc = str_contains(strtolower($EVENT), 'encrypted') ? 1 : 0;

$dt = new DateTime($TIMESTAMP);
$year  = (int)$dt->format('Y');
$month = (int)$dt->format('n');
$day   = (int)$dt->format('j');
$hour  = (int)$dt->format('G');
$minutes = (int)$dt->format('i');
$qtrhour = (int)ltrim(floor($minutes / 15) + 1);
$TO = (int)$TO;

// SQL logic is to update existing rows to track activity and if the update fails, then add the row needed for that date/time
// SQL DB tracks activity by the quarter-hour to prepare the data for a graph display based on quarter-hour segments

$_pdo_stmt = "UPDATE `activity` SET `count` = `count` + 1, `time` = `time` + :duration WHERE `node` = :NODE AND `region` = :REGION AND `tgSystem` = :tgSystem AND `tgDec` = :TO AND `enc` = :enc AND `year` = :year AND `month` = :month AND `day` = :day AND `hour` = :hour AND `qtrhour` = :qtrhour;";
$_pdo_args = array(":duration" =>$duration,":NODE"=>$NODE,":REGION"=>$REGION,":tgSystem"=>$tgSystem,":TO"=>$TO,":enc"=>$enc,":year"=>$year,":month"=>$month,":day"=>$day,":hour"=>$hour,":qtrhour"=>$qtrhour);
$result = queryPDO_single($default_db_id,$_pdo_stmt,$_pdo_args); $_pdo_stmt = $_pdo_args = NULL;
//error_log(json_encode($result));

if( $result["rowcount"] == 0 ) {
	//error_log("[INBOX_SDRLOGS] INSERTING NEW ROW");
	$_pdo_stmt = "INSERT INTO `activity` (
		`node`, `region`, `tgSystem`, `tgDec`, `enc`, 
		`year`, `month`, `day`, `hour`, `qtrhour`, 
		`count`, `time`
	) VALUES (
		:NODE, :REGION, :tgSystem, :TO, :enc, 
		:year, :month, :day, :hour, :qtrhour, 
		1, :duration
	);";
	$_pdo_args = array(":duration" =>$duration,":NODE"=>$NODE,":REGION"=>$REGION,":tgSystem"=>$tgSystem,":TO"=>$TO,":enc"=>$enc,":year"=>$year,":month"=>$month,":day"=>$day,":hour"=>$hour,":qtrhour"=>$qtrhour);
	$result = queryPDO_single($default_db_id,$_pdo_stmt,$_pdo_args); $_pdo_stmt = $_pdo_args = NULL;
	//error_log(json_encode($result));
}
else { 
//error_log("[INBOX_SDRLOGS] UPDATED EXISTING ROW"); 
}

// 6. Explicitly clean memory references to incoming objects (Garbage collection prep)
unset($rawPayload);
unset($decodedData);

// 7. Emit success payload response back to client architecture loop sequence
http_response_code(200);
echo json_encode(["status" => "ok"]);

error_log("[INBOX_SDRLOGS] --- Processing concluded ---");

exit();
?>