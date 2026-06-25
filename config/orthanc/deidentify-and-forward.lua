-- AIS-Edge Orthanc label hook.
--
-- The facility scanners are expected to send already-deidentified DICOMs.
-- This hook must not modify, delete, back up, or re-store DICOM instances.
-- It only marks stable studies with the label consumed by xnat-ingest sort.

local READY_LABEL = os.getenv("AIS_INGEST_READY_LABEL") or "xnat-ingest-ready"

local function utcNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function OnStoredInstance(instanceId, tags, metadata, origin)
  if origin.RequestOrigin ~= "DicomProtocol" then return end

  print(DumpJson({
    ts        = utcNow(),
    component = "orthanc-label",
    event     = "instance_received",
    instanceId = instanceId,
    calledAet = origin.CalledAet or "UNKNOWN"
  }, false))
end

function OnStableStudy(studyId, tags, metadata)
  RestApiPut("/studies/" .. studyId .. "/labels/" .. READY_LABEL, "")

  print(DumpJson({
    ts        = utcNow(),
    component = "orthanc-label",
    event     = "study_labeled_ready",
    studyId   = studyId,
    label     = READY_LABEL
  }, false))
end
