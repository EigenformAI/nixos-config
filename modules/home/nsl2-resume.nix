# systemd user unit for resuming nsl2 training runs after a reboot.
#
# Strict resume-only: the unit fires only if scripts/run_train_loop_resumable.sh
# in the nsl2 repo has armed a run by writing ~/.local/state/nsl2/active-run.
# A clean exit (or user SIGINT/SIGTERM) clears that state file; a crash leaves
# it so this unit re-launches the same --run-id on next boot.
#
# Companion linger setting lives in modules/common/users.nix
# (users.users.elijah.linger = true) so the user manager starts pre-login.
{ config, lib, pkgs, ... }:

{
  systemd.user.services.nsl2-resume = {
    Unit = {
      Description = "Resume nsl2 training run after reboot (strict resume-only)";
      Documentation = "file://%h/nsl2/scripts/resume_train_loop.sh";
      ConditionPathExists = "%h/.local/state/nsl2/active-run";
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/nsl2/scripts/resume_train_loop.sh";
      Restart = "no";
      TimeoutStartSec = "infinity";
      StandardOutput = "journal";
      StandardError = "journal";
      Environment =
        "PATH=/run/current-system/sw/bin:/run/wrappers/bin:%h/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
