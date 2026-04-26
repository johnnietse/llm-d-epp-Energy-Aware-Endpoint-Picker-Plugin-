package signals

// SCIScore represents a Software Carbon Intensity score per the Green Software
// Foundation ISO Standard (ISO/IEC 21031:2024).
//
// The SCI is the industry standard for measuring software carbon efficiency.
// Lower scores indicate more carbon-efficient software.
//
// Formula: SCI = ((E × I) + M) / R
//
//   - E: Energy consumed per functional unit (kWh)
//   - I: Grid carbon intensity (gCO2eq/kWh)
//   - M: Embodied emissions amortized per functional unit (gCO2eq)
//   - R: Functional unit (1 inference request in our context)
//
// Reference: https://sci.greensoftware.foundation/
type SCIScore struct {
	// E_kWh is the energy consumed per functional unit in kWh.
	E_kWh float64

	// I_gCO2_kWh is the marginal carbon intensity of the grid in gCO2eq/kWh.
	I_gCO2_kWh float64

	// M_gCO2 is the embodied carbon per functional unit in gCO2eq.
	// This accounts for hardware manufacturing emissions amortized over the
	// hardware's expected lifetime.
	M_gCO2 float64

	// OperationalCarbon_gCO2 is E × I — the carbon from electricity used.
	OperationalCarbon_gCO2 float64

	// SCI_gCO2 is the final Software Carbon Intensity score in gCO2eq per
	// functional unit. SCI = (E × I) + M.
	SCI_gCO2 float64
}

// HardwareEmbodiedCarbon holds the embodied (manufacturing) carbon data for
// a hardware accelerator, used to compute the M component of SCI.
type HardwareEmbodiedCarbon struct {
	// TotalEmbodied_kgCO2 is the total CO2 emitted during manufacturing.
	// Example: NVIDIA H100 ≈ 150 kgCO2, Qualcomm Cloud AI 100 ≈ 20 kgCO2.
	TotalEmbodied_kgCO2 float64

	// ExpectedLifetime_hours is the expected operational lifetime in hours.
	// Typical server: 4 years = 35,040 hours.
	ExpectedLifetime_hours float64
}

// DefaultEmbodiedCarbon returns conservative estimates for embodied carbon by
// hardware class. These values are derived from lifecycle assessment (LCA)
// literature and manufacturer sustainability reports.
func DefaultEmbodiedCarbon(class HardwareClass) HardwareEmbodiedCarbon {
	fourYears := 4.0 * 365.25 * 24 // ~35,064 hours

	switch class {
	case GPU_HIGH_PERF:
		// NVIDIA H100: ~150 kgCO2 (includes packaging, TSMC fab, HBM3)
		return HardwareEmbodiedCarbon{TotalEmbodied_kgCO2: 150.0, ExpectedLifetime_hours: fourYears}
	case GPU_MED_PERF:
		// NVIDIA A100/L4: ~40-100 kgCO2
		return HardwareEmbodiedCarbon{TotalEmbodied_kgCO2: 70.0, ExpectedLifetime_hours: fourYears}
	case ASIC_LOW_POWER:
		// Qualcomm Cloud AI 100: ~20 kgCO2 (smaller die, simpler packaging)
		return HardwareEmbodiedCarbon{TotalEmbodied_kgCO2: 20.0, ExpectedLifetime_hours: fourYears}
	case FPGA_LOW_POWER:
		return HardwareEmbodiedCarbon{TotalEmbodied_kgCO2: 30.0, ExpectedLifetime_hours: fourYears}
	default:
		return HardwareEmbodiedCarbon{TotalEmbodied_kgCO2: 50.0, ExpectedLifetime_hours: fourYears}
	}
}

// ComputeSCI calculates the Software Carbon Intensity score for a single
// inference request on the given pod.
//
// The functional unit R = 1 inference request.
// Energy E is derived from the pod's power draw and inference throughput:
//
//	E = CurrentPower_W / TokensPerSecond / 1000 / 3600  (kWh per token)
//
// For a request with avgTokenCount tokens, total energy = E × avgTokenCount.
//
// Parameters:
//   - profile: The pod's current energy telemetry
//   - ext: Current external signals (grid carbon intensity)
//   - embodied: Hardware manufacturing carbon data
//   - avgTokensPerRequest: Average number of tokens per inference request
func ComputeSCI(
	profile EnergyProfile,
	ext ExternalSignals,
	embodied HardwareEmbodiedCarbon,
	avgTokensPerRequest float64,
) SCIScore {
	if avgTokensPerRequest <= 0 {
		avgTokensPerRequest = 256 // reasonable default for LLM output
	}

	// E: Energy per request (kWh)
	// = (power_W × time_per_request_s) / 1000
	// time_per_request = avgTokensPerRequest / TokensPerSecond
	var e_kWh float64
	if profile.TokensPerSecond > 0 {
		timePerRequest_s := avgTokensPerRequest / profile.TokensPerSecond
		e_kWh = (profile.CurrentPower_W * timePerRequest_s) / 1000.0 / 3600.0
	} else if profile.EnergyPerToken_mJ > 0 {
		// Fallback: use EnergyPerToken_mJ directly
		e_kWh = profile.EnergyPerToken_mJ * avgTokensPerRequest / 1e6 / 3.6
	}

	// I: Grid carbon intensity (gCO2/kWh)
	i_gCO2 := ext.CarbonIntensity_gCO2_kWh
	if i_gCO2 <= 0 {
		i_gCO2 = 390.0 // US grid average fallback
	}

	// M: Embodied carbon per request (gCO2)
	// = TotalEmbodied_kgCO2 × 1000 / ExpectedLifetime_hours / 3600 × timePerRequest_s
	var m_gCO2 float64
	if embodied.ExpectedLifetime_hours > 0 && profile.TokensPerSecond > 0 {
		timePerRequest_s := avgTokensPerRequest / profile.TokensPerSecond
		embodiedPerSecond_gCO2 := (embodied.TotalEmbodied_kgCO2 * 1000.0) /
			(embodied.ExpectedLifetime_hours * 3600.0)
		m_gCO2 = embodiedPerSecond_gCO2 * timePerRequest_s
	}

	// SCI = (E × I) + M
	operationalCarbon := e_kWh * i_gCO2
	sci := operationalCarbon + m_gCO2

	return SCIScore{
		E_kWh:                  e_kWh,
		I_gCO2_kWh:            i_gCO2,
		M_gCO2:                m_gCO2,
		OperationalCarbon_gCO2: operationalCarbon,
		SCI_gCO2:              sci,
	}
}

// ComputeClusterSCI computes the weighted average SCI across all pods in the cluster.
func ComputeClusterSCI(
	profiles map[string]EnergyProfile,
	ext ExternalSignals,
	avgTokensPerRequest float64,
) SCIScore {
	if len(profiles) == 0 {
		return SCIScore{}
	}

	var totalSCI, totalE, totalM, totalOp float64
	for _, p := range profiles {
		embodied := DefaultEmbodiedCarbon(p.HardwareClass)
		sci := ComputeSCI(p, ext, embodied, avgTokensPerRequest)
		totalSCI += sci.SCI_gCO2
		totalE += sci.E_kWh
		totalM += sci.M_gCO2
		totalOp += sci.OperationalCarbon_gCO2
	}

	n := float64(len(profiles))
	return SCIScore{
		E_kWh:                  totalE / n,
		I_gCO2_kWh:            ext.CarbonIntensity_gCO2_kWh,
		M_gCO2:                totalM / n,
		OperationalCarbon_gCO2: totalOp / n,
		SCI_gCO2:              totalSCI / n,
	}
}
