# SDRTrunk_Log_Uplader
A utility to parse and upload the event logs from SDRTrunk

This utility runs as a Linux service using a 5-min timer, parses the event_log files that SDRTrunk produces, produces a JSON file for every GROUP CALL and ENCRYPTED GROUP CALL, and then posts those files to a destination URL.

The uploader is a simple post with no true API auth.  Quick and dirty.

A sample receiver PHP script is included (inbox_sdrtlogs.php)
