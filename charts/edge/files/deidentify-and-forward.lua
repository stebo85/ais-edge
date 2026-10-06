-- AIS-Edge Orthanc deidentify-and-forward hook.
--
-- OnStoredInstance: facility-backup the original, /modify against the
--   deidentification profile, delete the original (keep the deid'd one).
-- OnStableStudy:    PUT `xnat-ingest-ready` label on the study.
--
-- Inputs (mounted at /etc/orthanc/):
--   routing.json                     AET -> { project } map + default paths
--   deidentification-profile.json    Replace / Keep blocks for /modify
--   AIS_DEID_HMAC_SALT (env)         secret salt for SubjectHash/SessionHash
--
-- See docs/components/orthanc.md for failure-recovery + operations notes.

local ROUTING_FILE = os.getenv("AIS_ROUTING_FILE") or "/etc/orthanc/routing.json"
local HMAC_SALT    = os.getenv("AIS_DEID_HMAC_SALT") or error("AIS_DEID_HMAC_SALT not set")

local function loadJsonFile(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return ParseJson(content)
end

-- Salted djb2. NOT cryptographic; jodogne/orthanc-plugins doesn't expose
-- ComputeMd5/Sha1 in Lua. For HMAC-grade switch to jodogne/orthanc-python.
local function hmacShort(value, length)
  local input = HMAC_SALT .. "|" .. value
  local h1, h2 = 5381, 0
  for i = 1, #input do
    local c = string.byte(input, i)
    h1 = ((h1 * 33) + c) % 4294967296                -- djb2
    h2 = ((h2 * 31) + c + (h1 % 256)) % 4294967296   -- second mix for more entropy
  end
  local hex = string.format("%08X%08X", h1, h2)
  while #hex < (length or 12) do hex = hex .. hex end
  return string.sub(hex, 1, length or 12):upper()
end

local function shellQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Atomic durable write: bytes -> <path>.tmp, fsync, rename to <path>.
local function writeAtomic(path, bytes)
  local dir = string.match(path, "(.*)/[^/]+$")
  local tmp = path .. ".tmp"
  if dir then os.execute("mkdir -p " .. shellQuote(dir)) end

  local f, err = io.open(tmp, "wb")
  if not f then
    print("ERROR opening " .. tmp .. ": " .. (err or "unknown"))
    return false
  end
  f:write(bytes)
  f:close()

  os.execute("sync " .. shellQuote(tmp) .. " 2>/dev/null")
  local ok, _, rc = os.execute("mv -f " .. shellQuote(tmp) .. " " .. shellQuote(path))
  if not ok and rc ~= 0 then
    print("ERROR renaming " .. tmp .. " -> " .. path)
    os.remove(tmp)
    return false
  end
  return true
end

local function applyPlaceholders(profile, tags, project)
  -- NOT an HMAC despite the name; see the comment on hmacShort above. Salted
  -- djb2 truncated to 48 bits: collision-safe at any realistic cohort size, but
  -- NOT one-way. Anyone holding the salt can enumerate a medical-record-number
  -- space in minutes. The salt never leaves the edge, so this is not reversible
  -- from XNAT, which is the property the pipeline actually relies on.
  local subjectHash = hmacShort(tags.PatientID or "")
  local sessionHash = hmacShort((tags.PatientID or "") .. "|" .. (tags.StudyInstanceUID or ""))
  -- ZERO-LENGTH IS NOT ABSENT. Lua treats only nil and false as falsy, so a
  -- present-but-empty PatientBirthDate -- a legal and common DA value -- passes
  -- straight through `or`, string.sub("" ,1,4) returns "", and the profile
  -- resolves "${BirthYearOnly}0101" to the 4-character string "0101". That is
  -- not a valid DICOM date, and it is written into every instance of the study.
  -- Length is checked instead of truthiness.
  --
  -- MEASURED with lua5.3:
  --   "19551103" -> 19550101      ""  -> 0101          nil -> 19000101
  local rawBirth    = tags.PatientBirthDate
  local birthYear   = (rawBirth and #rawBirth >= 4)
                        and string.sub(rawBirth, 1, 4)
                        or "1900"

  local subs = {
    ["${ProjectCode}"]   = project,
    ["${SubjectHash}"]   = subjectHash,
    ["${SessionHash}"]   = sessionHash,
    ["${BirthYearOnly}"] = birthYear
  }

  for tag, template in pairs(profile.Replace or {}) do
    if type(template) == "string" then
      local resolved = template
      for placeholder, value in pairs(subs) do
        resolved = string.gsub(resolved, placeholder, value)
      end
      profile.Replace[tag] = resolved
    end
  end

  return profile, subjectHash, sessionHash
end

function OnStoredInstance(instanceId, tags, metadata, origin)
  -- Skip our own /modify outputs (origin "Lua") to avoid re-deiding deid'd output.
  if origin.RequestOrigin ~= "DicomProtocol" then return end

  local routing  = loadJsonFile(ROUTING_FILE)
  local calledAet = origin.CalledAet or "UNKNOWN"
  local backupDir = routing.Defaults.FacilityBackupDir

  -- Facility backup with original identifiers.
  local origBytes  = RestApiGet("/instances/" .. instanceId .. "/file")
  local backupPath = backupDir .. "/" ..
                     (tags.PatientID or "UNKNOWN") .. "/" ..
                     (tags.StudyInstanceUID or "UNKNOWN") .. "/" ..
                     (tags.SeriesInstanceUID or "UNKNOWN") .. "/" ..
                     (tags.SOPInstanceUID or instanceId) .. ".dcm"
  if not writeAtomic(backupPath, origBytes) then
    print("ABORT: facility backup write failed for " .. instanceId)
    return
  end

  -- THE ARCHIVE IS WRITTEN. Everything above is this script's job under EVERY
  -- engine, and it needs no AE map: the backup path is built from the DICOM
  -- tags alone. Everything BELOW is de-identification, including the AE-title
  -- lookup, which exists only to choose a project to de-identify into.
  --
  -- THAT ORDER IS LOAD-BEARING. Under another engine aetMap is legitimately
  -- empty, because the routing identifiers come from the data rather than from
  -- the AE title. With the lookup first, every study would miss it, be
  -- quarantined as unmapped AND DELETED FROM ORTHANC, and group would find
  -- nothing: the archive would fill up and the pipeline would deliver nothing.
  --
  -- Returning here leaves the instance in Orthanc for group to collect, and
  -- leaves it unmodified. De-identifying it here as well would make the
  -- re-identification map the other stage writes record pseudonyms rather than
  -- originals, so it would reverse to nothing while appearing to work.
  --
  -- The profile is loaded BELOW this point on purpose: under another engine
  -- there may be no profile file configured at all, and loading it here would
  -- fail the hook on every instance.
  if routing.Defaults.DeidEnabled == false then
    print(DumpJson({
      ts         = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      component  = "orthanc-deid",
      event      = "instance_archived",
      calledAet  = calledAet,
      instanceId = instanceId,
      backupPath = backupPath
    }, false))
    return
  end

  local mapping   = routing.AETMap[calledAet]
  if mapping == nil then
    -- QUARANTINE, don't destroy. The sending modality has already been given
    -- a C-STORE SUCCESS, so it will never retry — discarding the instance
    -- here would be permanent, silent data loss (a new scanner or a mistyped
    -- AE title is enough to trigger it).
    --
    -- Instead we write the ORIGINAL bytes (identifiers intact — this is the
    -- facility-side store, same trust boundary as the normal backup below)
    -- into a dedicated quarantine tree:
    --   <FacilityBackupDir>/__unmapped_aet__/<AET>/<PatientID>/<StudyUID>/<SOPUID>.dcm
    -- Once the AET is added to routing.json's AETMap the study can simply be
    -- re-sent/re-imported from there.
    --
    -- The instance is removed from Orthanc ONLY if the quarantine write
    -- succeeded; otherwise we keep it in Orthanc so nothing is ever lost.
    local qDir = (routing.Defaults or {}).FacilityBackupDir
    if qDir == nil then
      print("ABORT: no FacilityBackupDir configured; keeping unmapped instance "
            .. instanceId .. " in Orthanc (CalledAET " .. calledAet .. ")")
      return
    end
    local qBytes = RestApiGet("/instances/" .. instanceId .. "/file")
    local qPath  = qDir .. "/__unmapped_aet__/" .. calledAet .. "/" ..
                   (tags.PatientID or "UNKNOWN") .. "/" ..
                   (tags.StudyInstanceUID or "UNKNOWN") .. "/" ..
                   (tags.SOPInstanceUID or instanceId) .. ".dcm"
    if writeAtomic(qPath, qBytes) then
      -- Keep the "REJECT: no project mapped for CalledAET <AET>" wording:
      -- the DICOMRejectedUnmappedAET alert rule matches on it.
      print("REJECT: no project mapped for CalledAET " .. calledAet ..
            " — quarantined to " .. qPath)
      RestApiDelete("/instances/" .. instanceId)
    else
      print("REJECT: no project mapped for CalledAET " .. calledAet ..
            " — QUARANTINE WRITE FAILED, keeping instance " .. instanceId ..
            " in Orthanc")
    end
    return
  end

  local profile   = loadJsonFile(routing.Defaults.DeidentificationProfileFile)
  local mode      = profile.DeidMode or "modify"

  local subjectHash, sessionHash
  profile, subjectHash, sessionHash = applyPlaceholders(profile, tags, mapping.project)
  profile.DeidMode = nil  -- ais-only field; /modify rejects unknown fields
  local endpoint = "/instances/" .. instanceId .. "/" ..
                   (mode == "anonymize" and "anonymize" or "modify")

  -- /instances/{id}/modify returns DICOM bytes (NOT JSON) and does NOT store
  -- the result. We delete the original then POST the bytes back to /instances
  -- so the deid'd copy lands in Orthanc storage. The profile's Keep block
  -- preserves StudyInstanceUID so it joins the same Study.
  local ok, modifiedBytes = pcall(RestApiPost, endpoint, DumpJson(profile, true))
  if not ok or modifiedBytes == nil or modifiedBytes == "" then
    print("ABORT: " .. endpoint .. " failed: " .. tostring(modifiedBytes))
    return
  end
  RestApiDelete("/instances/" .. instanceId)  -- must delete before POST or UID collides
  local storeOk, storeResp = pcall(RestApiPost, "/instances", modifiedBytes)
  if not storeOk or storeResp == nil or storeResp == "" then
    print("ABORT: POST /instances failed: " .. tostring(storeResp))
    return
  end
  local parsed = ParseJson(storeResp)
  if parsed == nil or parsed["ID"] == nil then
    print("ABORT: POST /instances response has no ID: " .. tostring(storeResp))
    return
  end
  local newId = parsed["ID"]

  print(DumpJson({
    ts          = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    component   = "orthanc-deid",
    event       = "instance_deidentified",
    mode        = mode,
    calledAet   = calledAet,
    project     = mapping.project,
    session     = mapping.project .. "." .. subjectHash .. "." .. sessionHash,
    originalId  = instanceId,
    newId       = newId,
    backupPath  = backupPath
  }, false))
end

function OnStableStudy(studyId, tags, metadata)
  -- Fires StableAge seconds after the last instance arrives. By now
  -- OnStoredInstance has run for every instance; the study contains only
  -- deid'd copies. Label idempotently so sort picks it up (filters
  -- --orthanc-label xnat-ingest-ready and --orthanc-skip-label xnat-ingest-skip).
  RestApiPut("/studies/" .. studyId .. "/labels/xnat-ingest-ready", "")

  print(DumpJson({
    ts        = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    component = "orthanc-deid",
    event     = "study_labeled_ready",
    studyId   = studyId,
    label     = "xnat-ingest-ready"
  }, false))
end
