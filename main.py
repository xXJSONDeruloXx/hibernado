import os
import subprocess
import re
from pathlib import Path
import decky
import asyncio


class Plugin:
    def _reset_boot_counter(self):
        """Reset the boot counter to prevent 'failed to boot' menu after hibernation

        SteamOS uses steamos-bootconf to track boot attempts. After resuming from hibernation,
        the system hasn't actually failed to boot, so we reset the counter.
        """
        try:
            result = subprocess.run(
                ["/usr/bin/steamos-bootconf", "set-mode", "booted"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                decky.logger.info("Boot counter reset via steamos-bootconf")
                return True
            else:
                decky.logger.warning(f"Could not reset boot counter: {result.stderr}")
                return False
        except FileNotFoundError:
            # Try systemd-bless-boot as fallback for non-SteamOS systems
            try:
                result = subprocess.run(
                    ["/usr/bin/systemctl", "start", "systemd-bless-boot.service"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    decky.logger.info("Boot counter reset via systemd-bless-boot")
                    return True
            except Exception:
                pass

            decky.logger.debug("Boot counter reset not available on this system")
            return False
        except Exception as e:
            decky.logger.warning(f"Failed to reset boot counter: {e}")
            return False

    async def _main(self):
        self.loop = asyncio.get_event_loop()
        self._reset_boot_counter()

        import pwd

        effective_user = pwd.getpwuid(os.getuid()).pw_name
        decky.logger.info(
            f"Plugin running as user: {effective_user} (UID: {os.getuid()})"
        )

        plugin_dir = Path(decky.DECKY_PLUGIN_DIR)
        self.helper_script = plugin_dir / "bin" / "hibernate-helper.sh"

        if self.helper_script.exists():
            os.chmod(self.helper_script, 0o755)
            decky.logger.info(
                f"hibernado plugin loaded! Helper script: {self.helper_script}"
            )
        else:
            decky.logger.error(f"Helper script not found at {self.helper_script}")

    def _run_helper(
        self, action: str, *args, timeout: int = 60
    ) -> tuple[int, str, str]:
        """Run the helper script with the given action and optional arguments"""
        try:
            cmd = [str(self.helper_script), action] + list(args)
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as e:
            return -1, "", f"Timeout after {timeout} seconds"
        except Exception as e:
            return -1, "", str(e)

    async def _unload(self):
        decky.logger.info("hibernado plugin unloading...")
        pass

    async def _uninstall(self):
        decky.logger.info(
            "hibernado plugin uninstalling - cleaning up hibernation setup..."
        )
        try:
            returncode, stdout, stderr = self._run_helper("cleanup", timeout=60)

            if returncode != 0:
                decky.logger.error(f"Cleanup failed: {stderr}")
            else:
                decky.logger.info("Hibernation setup cleaned up successfully")

        except Exception as e:
            decky.logger.error(f"Error during uninstall cleanup: {e}")

        decky.logger.info("hibernado plugin uninstalled!")

    async def _migration(self):
        decky.logger.info("Migrating hibernado settings...")
        pass

    async def cleanup_hibernate(self) -> dict:
        """Remove all hibernation configuration without uninstalling the plugin"""
        try:
            decky.logger.info("User requested cleanup of hibernation configuration...")

            returncode, stdout, stderr = self._run_helper("cleanup", timeout=60)

            if returncode != 0:
                error_msg = stderr or "Unknown error during cleanup"
                decky.logger.error(f"Cleanup failed: {error_msg}")
                return {"success": False, "error": error_msg}

            decky.logger.info("Hibernation configuration cleaned up successfully")
            return {
                "success": True,
                "message": "All hibernation configuration removed. Reboot recommended.",
            }

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error during cleanup: {error_msg}")
            return {"success": False, "error": error_msg}

    async def check_hibernate_status(self) -> dict:
        """Check if hibernation is currently set up and ready"""
        try:
            decky.logger.info("Checking hibernate status...")

            returncode, stdout, stderr = self._run_helper("status", timeout=5)

            if returncode != 0:
                decky.logger.error(f"Status check failed: {stderr}")
                return {
                    "success": False,
                    "error": stderr,
                    "ready": False,
                    "status_code": "ERROR",
                    "power_button_override": False,
                    "override_mode": "hibernate",
                }

            status = stdout.strip()
            decky.logger.info(f"Hibernate status: {status}")

            # Check power button override status
            power_button_override = False
            override_mode = "hibernate"

            try:
                # Check if the symlink exists
                symlink_path = "/etc/systemd/system/systemd-suspend.service"
                if os.path.islink(symlink_path):
                    target = os.readlink(symlink_path)
                    if "suspend-then-hibernate" in target:
                        power_button_override = True
                        override_mode = "suspend-then-hibernate"
                    elif "hibernate" in target:
                        power_button_override = True
                        override_mode = "hibernate"
            except Exception as e:
                decky.logger.warning(
                    f"Could not check power button override status: {e}"
                )

            status_map = {
                "READY": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": True,
                    "resume_configured": True,
                    "systemd_configured": True,
                    "bluetooth_fix": True,
                    "sleep_conf": True,
                    "ready": True,
                    "status_code": "READY",
                    "message": "Hibernation fully configured and ready",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "SWAPFILE_MISSING": {
                    "success": True,
                    "swapfile_exists": False,
                    "swap_active": False,
                    "resume_configured": False,
                    "ready": False,
                    "status_code": "SWAPFILE_MISSING",
                    "message": "Swapfile not found - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "SWAPFILE_TOO_SMALL": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": False,
                    "resume_configured": False,
                    "ready": False,
                    "status_code": "SWAPFILE_TOO_SMALL",
                    "message": "Swapfile too small (need 16GB+) - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "SWAP_INACTIVE": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": False,
                    "resume_configured": False,
                    "ready": False,
                    "status_code": "SWAP_INACTIVE",
                    "message": "Swapfile exists but not activated - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "RESUME_NOT_CONFIGURED": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": True,
                    "resume_configured": False,
                    "ready": False,
                    "status_code": "RESUME_NOT_CONFIGURED",
                    "message": "Resume parameters not configured - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "SYSTEMD_NOT_CONFIGURED": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": True,
                    "resume_configured": True,
                    "systemd_configured": False,
                    "ready": False,
                    "status_code": "SYSTEMD_NOT_CONFIGURED",
                    "message": "Systemd bypass not configured - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "BLUETOOTH_FIX_MISSING": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": True,
                    "resume_configured": True,
                    "systemd_configured": True,
                    "bluetooth_fix": False,
                    "ready": False,
                    "status_code": "BLUETOOTH_FIX_MISSING",
                    "message": "Bluetooth fix service missing - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
                "SLEEP_CONF_NOT_CONFIGURED": {
                    "success": True,
                    "swapfile_exists": True,
                    "swap_active": True,
                    "resume_configured": True,
                    "systemd_configured": True,
                    "bluetooth_fix": True,
                    "sleep_conf": False,
                    "ready": False,
                    "status_code": "SLEEP_CONF_NOT_CONFIGURED",
                    "message": "Sleep configuration missing - setup required",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
            }

            return status_map.get(
                status,
                {
                    "success": True,
                    "ready": False,
                    "status_code": "UNKNOWN",
                    "message": f"Unknown status: {status}",
                    "power_button_override": power_button_override,
                    "override_mode": override_mode,
                },
            )

        except Exception as e:
            decky.logger.error(f"Error in check_hibernate_status: {e}")
            return {
                "success": False,
                "error": str(e),
                "ready": False,
                "status_code": "ERROR",
                "power_button_override": False,
                "override_mode": "hibernate",
            }

    async def prepare_hibernate(self) -> dict:
        """Prepare the system for hibernation by setting up swap and resume parameters"""
        try:
            decky.logger.info("Starting hibernate preparation...")
            returncode, stdout, stderr = self._run_helper("prepare", timeout=120)

            decky.logger.info(f"Helper script returncode: {returncode}")
            if stdout:
                decky.logger.info(f"Helper script stdout: {stdout}")
            if stderr:
                decky.logger.error(f"Helper script stderr: {stderr}")

            if returncode != 0:
                error_msg = stderr or "Unknown error during setup"
                decky.logger.error(f"Hibernate preparation failed: {error_msg}")
                return {"success": False, "error": error_msg}

            # Parse output for UUID and offset
            output = stdout.strip()
            if "SUCCESS:" in output:
                parts = output.split("SUCCESS:")[1].split(":")
                uuid = parts[0] if len(parts) > 0 else "unknown"
                offset = parts[1] if len(parts) > 1 else "unknown"

                decky.logger.info(
                    f"Hibernate setup complete - UUID: {uuid}, Offset: {offset}"
                )

                return {
                    "success": True,
                    "message": "Hibernation setup completed successfully",
                    "uuid": uuid,
                    "offset": offset,
                }
            else:
                decky.logger.info("Hibernate setup completed")
                return {
                    "success": True,
                    "message": "Hibernation setup completed successfully",
                }

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error in prepare_hibernate: {error_msg}")
            return {"success": False, "error": error_msg}

    async def trigger_hibernate(self) -> dict:
        """Trigger system hibernation"""
        try:
            self._reset_boot_counter()
            decky.logger.info("Triggering hibernation...")

            try:
                result = subprocess.run(
                    ["findmnt", "-no", "SOURCE", "-T", "/home"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )

                if result.returncode != 0:
                    raise Exception("Could not find /home device")

                dev_path = result.stdout.strip()
                decky.logger.info(f"Found /home device: {dev_path}")

                stat_result = subprocess.run(
                    ["stat", "-c", "%t:%T", dev_path],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )

                if stat_result.returncode != 0:
                    raise Exception("Could not stat device")

                major_hex, minor_hex = stat_result.stdout.strip().split(":")
                major = int(major_hex, 16)
                minor = int(minor_hex, 16)
                resume_dev = f"{major}:{minor}"
                decky.logger.info(f"Device numbers: {resume_dev}")

                # Get swapfile offset
                result = subprocess.run(
                    ["filefrag", "-v", "/home/swapfile"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )

                if result.returncode != 0:
                    raise Exception("Could not get swapfile offset")

                for line in result.stdout.splitlines():
                    if line.strip().startswith("0:"):
                        parts = line.split()
                        if len(parts) >= 4:
                            offset = parts[3].rstrip(".")
                            decky.logger.info(f"Swapfile offset: {offset}")
                            break
                else:
                    raise Exception("Could not parse swapfile offset")

                decky.logger.info(
                    f"Setting resume device to {resume_dev}, offset {offset}"
                )

                with open("/sys/power/resume", "w") as f:
                    f.write(f"{resume_dev}\n")
                    f.flush()

                with open("/sys/power/resume_offset", "w") as f:
                    f.write(f"{offset}\n")
                    f.flush()

                decky.logger.info("Resume parameters set successfully")

            except Exception as resume_error:
                error_msg = f"Failed to set resume parameters: {resume_error}"
                decky.logger.error(error_msg)
                return {"success": False, "error": error_msg}

            try:
                with open("/sys/power/disk", "w") as f:
                    f.write("platform\n")
                    f.flush()
                decky.logger.info("Hibernation mode set to 'platform'")
            except Exception as disk_error:
                decky.logger.warning(f"Could not set /sys/power/disk: {disk_error}")

            subprocess.run(["/usr/bin/sync"], check=False)

            try:
                with open("/sys/power/state", "w") as f:
                    f.write("disk\n")
                    f.flush()
            except Exception as write_error:
                error_msg = f"Failed to write to /sys/power/state: {write_error}"
                decky.logger.error(error_msg)
                return {"success": False, "error": error_msg}

            decky.logger.info("Hibernation triggered successfully")
            return {"success": True, "message": "System is hibernating..."}

        except Exception as e:
            if "timeout" in str(e).lower() or "timed out" in str(e).lower():
                decky.logger.info("Hibernation command sent (timeout expected)")
                return {"success": True, "message": "System is hibernating..."}

            error_msg = str(e)
            decky.logger.error(f"Error in trigger_hibernate: {error_msg}")
            return {"success": False, "error": error_msg}

    async def hibernate_now(self) -> dict:
        """Complete hibernate workflow: prepare (if needed) and hibernate"""
        try:
            decky.logger.info("Starting complete hibernate workflow...")

            status = await self.check_hibernate_status()

            if not status.get("ready", False):
                decky.logger.info("System not ready for hibernation, preparing...")

                prep_result = await self.prepare_hibernate()
                if not prep_result.get("success", False):
                    return prep_result
            else:
                decky.logger.info("System already configured for hibernation")

            return await self.trigger_hibernate()

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error in hibernate_now: {error_msg}")
            return {"success": False, "error": error_msg}

    async def suspend_then_hibernate(self) -> dict:
        """Suspend (sleep) first, then hibernate after configured delay"""
        try:
            decky.logger.info("Starting suspend-then-hibernate workflow...")

            status = await self.check_hibernate_status()

            if not status.get("ready", False):
                decky.logger.info("System not ready for hibernation, preparing...")

                prep_result = await self.prepare_hibernate()
                if not prep_result.get("success", False):
                    return prep_result
            else:
                decky.logger.info("System already configured for hibernation")

            self._reset_boot_counter()
            decky.logger.info("Triggering suspend-then-hibernate via systemctl...")

            returncode, stdout, stderr = self._run_helper(
                "suspend-then-hibernate", timeout=10
            )

            if returncode != 0:
                error_msg = stderr or "Unknown error during suspend-then-hibernate"
                decky.logger.error(f"Suspend-then-hibernate failed: {error_msg}")
                return {"success": False, "error": error_msg}

            decky.logger.info("Suspend-then-hibernate triggered successfully")
            return {
                "success": True,
                "message": "System is suspending, then will hibernate...",
            }

        except Exception as e:
            if "timeout" in str(e).lower() or "timed out" in str(e).lower():
                decky.logger.info(
                    "Suspend-then-hibernate command sent (timeout expected)"
                )
                return {
                    "success": True,
                    "message": "System is suspending, then will hibernate...",
                }

            error_msg = str(e)
            decky.logger.error(f"Error in suspend_then_hibernate: {error_msg}")
            return {"success": False, "error": error_msg}

    async def set_power_button_override(self, enabled: bool, mode: str) -> dict:
        """Enable or disable power button override for hibernation

        Args:
            enabled: True to enable override, False to disable
            mode: "hibernate" or "suspend-then-hibernate"
        """
        try:
            decky.logger.info(
                f"Setting power button override: enabled={enabled}, mode={mode}"
            )

            # Check if hibernation is ready
            status = await self.check_hibernate_status()
            if not status.get("ready", False):
                return {
                    "success": False,
                    "error": "Hibernation must be set up before enabling power button override",
                }

            # Build arguments for helper script
            if enabled:
                returncode, stdout, stderr = self._run_helper(
                    "set-power-button", "enable", mode, timeout=10
                )
            else:
                returncode, stdout, stderr = self._run_helper(
                    "set-power-button", "disable", timeout=10
                )

            if returncode != 0:
                error_msg = stderr or "Unknown error setting power button override"
                decky.logger.error(f"Power button override failed: {error_msg}")
                return {"success": False, "error": error_msg}

            decky.logger.info(
                f"Power button override {'enabled' if enabled else 'disabled'} successfully"
            )
            return {
                "success": True,
                "message": f"Power button override {'enabled' if enabled else 'disabled'}",
            }

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error in set_power_button_override: {error_msg}")
            return {"success": False, "error": error_msg}

    async def get_hibernate_delay(self) -> dict:
        """Get the current hibernate delay setting in minutes

        Returns:
            dict with success, delay_minutes
        """
        try:
            decky.logger.info("Getting hibernate delay setting...")

            returncode, stdout, stderr = self._run_helper("get-delay", timeout=5)

            if returncode != 0:
                decky.logger.warning(f"Could not get delay: {stderr}")
                # Default to 60 minutes if not found
                return {"success": True, "delay_minutes": 60}

            # Parse the output (should be just a number)
            delay_minutes = int(stdout.strip())
            decky.logger.info(f"Current hibernate delay: {delay_minutes} minutes")

            return {"success": True, "delay_minutes": delay_minutes}

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error getting hibernate delay: {error_msg}")
            return {
                "success": False,
                "error": error_msg,
                "delay_minutes": 60,  # Default fallback
            }

    async def set_hibernate_delay(self, delay_minutes: int) -> dict:
        """Set the hibernate delay for suspend-then-hibernate

        Args:
            delay_minutes: Delay in minutes before hibernating from suspend
        """
        try:
            decky.logger.info(f"Setting hibernate delay to {delay_minutes} minutes...")

            returncode, stdout, stderr = self._run_helper(
                "set-delay", str(delay_minutes), timeout=10
            )

            if returncode != 0:
                error_msg = stderr or "Unknown error setting hibernate delay"
                decky.logger.error(f"Set delay failed: {error_msg}")
                return {"success": False, "error": error_msg}

            decky.logger.info(
                f"Hibernate delay set to {delay_minutes} minutes successfully"
            )
            return {
                "success": True,
                "message": f"Hibernate delay set to {delay_minutes} minutes",
            }

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error setting hibernate delay: {error_msg}")
            return {"success": False, "error": error_msg}

    async def run_bluetooth_fixes(self) -> dict:
        """Run the Bluetooth/WiFi/Audio fix script on demand

        This executes the same fix-bluetooth.sh script that runs after hibernation resume,
        useful if Bluetooth, WiFi, or audio is misbehaving.
        """
        try:
            decky.logger.info("Running Bluetooth/WiFi/Audio fixes...")

            fix_script = "/home/deck/.local/bin/fix-bluetooth.sh"

            # Check if the script exists
            if not os.path.exists(fix_script):
                error_msg = "Fix script not found. Please set up hibernation first."
                decky.logger.error(error_msg)
                return {"success": False, "error": error_msg}

            # Run the fix script
            try:
                result = subprocess.run(
                    [fix_script],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                )

                decky.logger.info(
                    f"Fix script completed with return code: {result.returncode}"
                )
                if result.stdout:
                    decky.logger.info(f"Fix script output: {result.stdout}")
                if result.stderr:
                    decky.logger.warning(f"Fix script stderr: {result.stderr}")

                return {
                    "success": True,
                    "message": "Bluetooth/WiFi/Audio fixes applied successfully",
                }

            except subprocess.TimeoutExpired:
                error_msg = "Fix script timed out after 30 seconds"
                decky.logger.error(error_msg)
                return {"success": False, "error": error_msg}
            except Exception as e:
                error_msg = f"Failed to run fix script: {str(e)}"
                decky.logger.error(error_msg)
                return {"success": False, "error": error_msg}

        except Exception as e:
            error_msg = str(e)
            decky.logger.error(f"Error in run_bluetooth_fixes: {error_msg}")
            return {"success": False, "error": error_msg}
