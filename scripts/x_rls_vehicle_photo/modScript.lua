-- core_modmanager wraps extensions.load while modScripts run; load a moment later through the real loader
-- (as RLS does) so the extension gets its per-frame hooks.
core_jobsystem.create(function(job)
  job.sleep(0.5)
  setExtensionUnloadMode("xRlsVehiclePhoto", "manual")
  extensions.load("xRlsVehiclePhoto")
end)
