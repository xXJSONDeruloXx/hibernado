import {
  ButtonItem,
  PanelSection,
  PanelSectionRow,
  staticClasses,
  Field,
  ToggleField,
  Dropdown,
  SingleDropdownOption,
  ConfirmModal,
  showModal,
  ModalRoot,
  DialogButton,
  DialogBody,
  DialogBodyText,
  DialogHeader
} from "@decky/ui";
import {
  callable,
  definePlugin,
} from "@decky/api"
import { useState, useEffect } from "react";
import { FaTornado } from "react-icons/fa6";

const checkHibernateStatus = callable<[], any>("check_hibernate_status");
const prepareHibernate = callable<[], any>("prepare_hibernate");
const hibernateNow = callable<[], any>("hibernate_now");
const suspendThenHibernate = callable<[], any>("suspend_then_hibernate");
const cleanupHibernate = callable<[], any>("cleanup_hibernate");
const setPowerButtonOverride = callable<[boolean, string], any>("set_power_button_override");
const getHibernateDelay = callable<[], any>("get_hibernate_delay");
const setHibernateDelay = callable<[number], any>("set_hibernate_delay");
const getLowBatteryHibernateStatus = callable<[], any>("get_low_battery_hibernate_status");
const setLowBatteryHibernate = callable<[boolean, number], any>("set_low_battery_hibernate");

// Custom modal component that shows hibernating state before actually hibernating
function HibernateConfirmModal({ closeModal }: { closeModal?: () => void }) {
  const [isHibernating, setIsHibernating] = useState(false);

  // Auto-dismiss the modal after 4 seconds when hibernating
  // This ensures the modal is gone when the system wakes from hibernate
  useEffect(() => {
    if (isHibernating && closeModal) {
      const timer = setTimeout(() => {
        closeModal();
      }, 4000);
      return () => clearTimeout(timer);
    }
    return undefined;
  }, [isHibernating, closeModal]);

  const handleHibernate = async () => {
    setIsHibernating(true);
    
    // Wait 1 second to show the "Hibernating..." state
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    // Then trigger hibernate (screen may come back on showing this modal in hibernating state)
    try {
      await hibernateNow();
    } catch (error) {
      console.error("Hibernate failed:", error);
      setIsHibernating(false);
    }
  };

  if (isHibernating) {
    return (
      <ModalRoot closeModal={closeModal}>
        <DialogHeader>Hibernating...</DialogHeader>
        <DialogBody>
          <DialogBodyText>
            Saving state to disk and powering off. The screen may wake back up briefly - this is normal.
          </DialogBodyText>
        </DialogBody>
      </ModalRoot>
    );
  }

  return (
    <ModalRoot closeModal={closeModal}>
      <DialogHeader>Hibernate Now</DialogHeader>
      <DialogBody>
        <DialogBodyText>
          Hibernation saves your current state to disk and powers off. When you turn it back on, everything restores exactly as you left it. The screen may flicker and fans may run for up to 20 seconds before fully powering off. To wake, hold the power button slightly longer than usual.
        </DialogBodyText>
        <div style={{ display: "flex", gap: "10px", marginTop: "16px" }}>
          <DialogButton onClick={handleHibernate}>
            Hibernate Now
          </DialogButton>
          <DialogButton onClick={closeModal}>
            Cancel
          </DialogButton>
        </div>
      </DialogBody>
    </ModalRoot>
  );
}

function Content() {
  const [status, setStatus] = useState<any>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isSettingUp, setIsSettingUp] = useState(false);
  const [powerButtonOverride, setPowerButtonOverrideState] = useState(false);
  const [overrideMode, setOverrideMode] = useState<"hibernate" | "suspend-then-hibernate">("hibernate");
  const [hibernateDelayMinutes, setHibernateDelayMinutes] = useState<number>(60);
  const [lowBatteryHibernate, setLowBatteryHibernateState] = useState(false);
  const [lowBatteryThreshold, setLowBatteryThreshold] = useState<number>(5);

  useEffect(() => {
    loadStatus();

    const interval = setInterval(() => {
      loadStatus();
      if (isLoading) {
        setIsLoading(false);
      }
    }, 3000);

    return () => {
      clearInterval(interval);
    };
  }, [isLoading]);

  const loadStatus = async () => {
    try {
      const result = await checkHibernateStatus();
      setStatus(result);
      
      // Update power button override state from status
      if (result.power_button_override !== undefined) {
        setPowerButtonOverrideState(result.power_button_override);
      }
      if (result.override_mode) {
        setOverrideMode(result.override_mode);
      }
      
      // If setup is in progress and we're now ready, clear the setting up state
      if (isSettingUp && result.ready) {
        setIsSettingUp(false);
      }
      
      // Load hibernate delay setting
      if (result.ready) {
        const delayResult = await getHibernateDelay();
        if (delayResult.success && delayResult.delay_minutes) {
          setHibernateDelayMinutes(delayResult.delay_minutes);
        }
        
        // Load low battery hibernate status
        const lowBatteryResult = await getLowBatteryHibernateStatus();
        if (lowBatteryResult.success) {
          setLowBatteryHibernateState(lowBatteryResult.enabled);
          if (lowBatteryResult.threshold) {
            setLowBatteryThreshold(lowBatteryResult.threshold);
          }
        }
      }
    } catch (error) {
      console.error("Failed to check hibernate status:", error);
    }
  };

  const handlePrepare = async () => {
    setIsLoading(true);
    setIsSettingUp(true);
    
    try {
      const result = await prepareHibernate();
      
      if (result.success) {
        await loadStatus();
        // Keep isSettingUp true until loadStatus confirms ready
      } else {
        console.error("Setup failed:", result.error);
        setIsSettingUp(false);
      }
    } catch (error) {
      console.error("Prepare failed:", error);
      setIsSettingUp(false);
    } finally {
      setIsLoading(false);
    }
  };

  const showHibernateConfirmation = () => {
    showModal(<HibernateConfirmModal />);
  };

  const handleSuspendThenHibernate = async () => {
    setIsLoading(true);
    
    try {
      const result = await suspendThenHibernate();
      
      if (!result.success) {
        console.error("Suspend-then-hibernate failed:", result.error);
        setIsLoading(false);
      }
    } catch (error) {
      console.error("Suspend-then-hibernate failed:", error);
      setIsLoading(false);
    }
  };

  const handleCleanup = async () => {
    setIsLoading(true);
    
    try {
      const result = await cleanupHibernate();
      
      if (result.success) {
        await loadStatus();
      } else {
        console.error("Cleanup failed:", result.error);
      }
    } catch (error) {
      console.error("Cleanup failed:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const showCleanupConfirmation = () => {
    showModal(
      <ConfirmModal
        strTitle="Remove Hibernation"
        strDescription={
          "This will remove all hibernation configuration including the swapfile. " +
          "A reboot is recommended after removal.\n\n" +
          "Are you sure you want to remove hibernation setup?"
        }
        strOKButtonText="Remove"
        strCancelButtonText="Cancel"
        onOK={handleCleanup}
      />
    );
  };

  const handlePowerButtonOverrideToggle = async (enabled: boolean) => {
    setIsLoading(true);
    
    try {
      // Use the selected override mode
      const result = await setPowerButtonOverride(enabled, overrideMode);
      
      if (result.success) {
        setPowerButtonOverrideState(enabled);
        await loadStatus();
      } else {
        console.error("Power button override failed:", result.error);
      }
    } catch (error) {
      console.error("Power button override failed:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleOverrideModeChange = async (mode: "hibernate" | "suspend-then-hibernate") => {
    setOverrideMode(mode);
    
    // If override is currently enabled, apply the new mode
    if (powerButtonOverride) {
      setIsLoading(true);
      
      try {
        const result = await setPowerButtonOverride(true, mode);
        
        if (result.success) {
          await loadStatus();
        } else {
          console.error("Mode change failed:", result.error);
        }
      } catch (error) {
        console.error("Mode change failed:", error);
      } finally {
        setIsLoading(false);
      }
    }
  };

  const handleDelayChange = async (delayMinutes: number) => {
    setHibernateDelayMinutes(delayMinutes);
    
    try {
      const result = await setHibernateDelay(delayMinutes);
      
      if (!result.success) {
        console.error("Delay change failed:", result.error);
      }
    } catch (error) {
      console.error("Delay change failed:", error);
    }
  };

  const handleLowBatteryHibernateToggle = async (enabled: boolean) => {
    setIsLoading(true);
    
    try {
      const result = await setLowBatteryHibernate(enabled, lowBatteryThreshold);
      
      if (result.success) {
        setLowBatteryHibernateState(enabled);
        await loadStatus();
      } else {
        console.error("Low battery hibernate toggle failed:", result.error);
      }
    } catch (error) {
      console.error("Low battery hibernate toggle failed:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const formatDelayLabel = (minutes: number): string => {
    if (minutes < 60) {
      return `${minutes} min`;
    } else {
      const hours = minutes / 60;
      return `${hours} hr${hours !== 1 ? 's' : ''}`;
    }
  };

  return (
    <PanelSection>
      {status?.ready && (
        <>
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              onClick={showHibernateConfirmation}
            >
              Hibernate Now
            </ButtonItem>
          </PanelSectionRow>

          <PanelSectionRow>
            <ButtonItem
              layout="below"
              onClick={handleSuspendThenHibernate}
              disabled={isLoading}
            >
              {isLoading ? "Suspending..." : `Suspend → Hibernate (${formatDelayLabel(hibernateDelayMinutes)})`}
            </ButtonItem>
          </PanelSectionRow>

          <PanelSectionRow>
            <ToggleField
              label="Override Power Button"
              description={powerButtonOverride 
                ? (overrideMode === "hibernate" ? "Power button will hibernate immediately" : `Power button will suspend then hibernate after ${formatDelayLabel(hibernateDelayMinutes)}`)
                : "Power button works normally (suspend only)"
              }
              checked={powerButtonOverride}
              onChange={handlePowerButtonOverrideToggle}
              disabled={isLoading}
            />
          </PanelSectionRow>

          {powerButtonOverride && (
            <PanelSectionRow>
              <Field 
                label="Power Button Behavior"
                childrenLayout="below"
                childrenContainerWidth="max"
              >
                <Dropdown
                  rgOptions={[
                    {
                      data: "hibernate" as const,
                      label: "Hibernate Immediately"
                    },
                    {
                      data: "suspend-then-hibernate" as const,
                      label: `Suspend → Hibernate (${formatDelayLabel(hibernateDelayMinutes)})`
                    }
                  ]}
                  selectedOption={overrideMode}
                  onChange={(option: SingleDropdownOption) => handleOverrideModeChange(option.data as "hibernate" | "suspend-then-hibernate")}
                  disabled={isLoading}
                />
              </Field>
            </PanelSectionRow>
          )}
          
          <PanelSectionRow>
            <div
              style={{
                fontSize: "14px",
                fontWeight: "bold",
                marginTop: "8px",
                marginBottom: "6px",
                borderBottom: "1px solid rgba(255, 255, 255, 0.2)",
                paddingBottom: "3px",
                color: "white"
              }}
            >
              Suspend-Then-Hibernate Settings
            </div>
          </PanelSectionRow>

          <PanelSectionRow>
            <Field 
              label="Delay Before Hibernation"
              childrenLayout="below"
              childrenContainerWidth="max"
            >
              <Dropdown
                rgOptions={[
                  { data: 1, label: "1 minute" },
                  { data: 5, label: "5 minutes" },
                  { data: 10, label: "10 minutes" },
                  { data: 20, label: "20 minutes" },
                  { data: 30, label: "30 minutes" },
                  { data: 60, label: "1 hour" },
                  { data: 120, label: "2 hours" },
                  { data: 180, label: "3 hours" },
                  { data: 300, label: "5 hours" }
                ]}
                selectedOption={hibernateDelayMinutes}
                onChange={(option: SingleDropdownOption) => handleDelayChange(option.data as number)}
                disabled={isLoading}
              />
            </Field>
          </PanelSectionRow>

          <PanelSectionRow>
            <div
              style={{
                fontSize: "14px",
                fontWeight: "bold",
                marginTop: "8px",
                marginBottom: "6px",
                borderBottom: "1px solid rgba(255, 255, 255, 0.2)",
                paddingBottom: "3px",
                color: "white"
              }}
            >
              Battery Protection
            </div>
          </PanelSectionRow>

          <PanelSectionRow>
            <ToggleField
              label="Auto-Hibernate on Low Battery"
              description={lowBatteryHibernate 
                ? `Will hibernate when battery drops to ${lowBatteryThreshold}%`
                : "Disabled - battery can drain completely"
              }
              checked={lowBatteryHibernate}
              onChange={handleLowBatteryHibernateToggle}
              disabled={isLoading}
            />
          </PanelSectionRow>
        </>
      )}

      {!status?.ready && (
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            onClick={handlePrepare}
            disabled={isLoading || isSettingUp}
          >
            {(isLoading || isSettingUp) ? "Setting up..." : "Setup Hibernation"}
          </ButtonItem>
        </PanelSectionRow>
      )}

      {status && !status.success && (
        <PanelSectionRow>
          <div style={{ color: "#F44336", fontSize: "0.9em" }}>
            Error: {status.error}
          </div>
        </PanelSectionRow>
      )}
      
      {status?.ready && (
        <>
          <PanelSectionRow>
            <div style={{ fontSize: "0.75em", color: "#666", marginTop: "12px", fontStyle: "italic" }}>
              Hibernation saves RAM to disk and powers off. Resume is slower than sleep but preserves battery.
            </div>
          </PanelSectionRow>
          
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              onClick={showCleanupConfirmation}
            >
              Remove Hibernation
            </ButtonItem>
          </PanelSectionRow>
        </>
      )}
    </PanelSection>
  );
};

export default definePlugin(() => {
  console.log("hibernado plugin initializing...")

  return {
    name: "Hibernado",
    titleView: <div className={staticClasses.Title}>Hibernado</div>,
    alwaysRender: true,
    content: <Content />,
    icon: <FaTornado />,
    onDismount() {
      console.log("Hibernado unloading...")
    },
  };
});
