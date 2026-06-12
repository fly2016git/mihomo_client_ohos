package cpuid

// FeatureID mirrors the public type used by github.com/klauspost/cpuid/v2.
type FeatureID int

const (
	UNKNOWN FeatureID = -1

	ADX FeatureID = iota
	AESNI
	AMD3DNOW
	AMD3DNOWEXT
	AMXBF16
	AMXFP16
	AMXINT8
	AMXTILE
	APX_F
	AVX
	AVX10
	AVX10_128
	AVX10_256
	AVX10_512
	AVX2
	AVX512BF16
	AVX512BITALG
	AVX512BW
	AVX512CD
	AVX512DQ
	AVX512ER
	AVX512F
	AVX512FP16
	AVX512IFMA
	AVX512PF
	AVX512VBMI
	AVX512VBMI2
	AVX512VL
	AVX512VNNI
	AVX512VP2INTERSECT
	AVX512VPOPCNTDQ
	AVXIFMA
	AVXNECONVERT
	AVXSLOW
	AVXVNNI
	AVXVNNIINT8
	BHI_CTRL
	BMI1
	BMI2
	CETIBT
	CETSS
	CLDEMOTE
	CLMUL
	CLZERO
	CMOV
	CMPCCXADD
	CMPSB_SCADBS_SHORT
	CMPXCHG8
	CPBOOST
	CPPC
	CX16
	EFER_LMSLE_UNS
	ENQCMD
	ERMS
	F16C
	FLUSH_L1D
	FMA3
	FMA4
	FP128
	FP256
	FSRM
	FXSR
	FXSROPT
	GFNI
	HLE
	HRESET
	HTT
	HWA
	HYBRID_CPU
	HYPERVISOR
	IA32_ARCH_CAP
	IA32_CORE_CAP
	IBPB
	IBRS
	IBRS_PREFERRED
	IBRS_PROVIDES_SMP
	IBS
	IBSBRNTRGT
	IBSFETCHSAM
	IBSFFV
	IBSOPCNT
	IBSOPCNTEXT
	IBSOPSAM
	IBSRDWROPCNT
	IBSRIPINVALIDCHK
	IBS_FETCH_CTLX
	IBS_OPDATA4
	IBS_OPFUSE
	IBS_PREVENTHOST
	IBS_ZEN4
	IDPRED_CTRL
	INT_WBINVD
	INVLPGB
	KEYLOCKER
	KEYLOCKERW
	LAHF
	LAM
	LBRVIRT
	LZCNT
	MCAOVERFLOW
	MCDT_NO
	MCOMMIT
	MD_CLEAR
	MMX
	MMXEXT
	MOVBE
	MOVDIR64B
	MOVDIRI
	MOVSB_ZL
	MOVU
	MPX
	MSRIRC
	MSRLIST
	MSR_PAGEFLUSH
	NRIPS
	NX
	OSXSAVE
	PCONFIG
	POPCNT
	PPIN
	PREFETCHI
	PSFD
	RDPRU
	RDRAND
	RDSEED
	RDTSCP
	RRSBA_CTRL
	RTM
	RTM_ALWAYS_ABORT
	SERIALIZE
	SEV
	SEV_64BIT
	SEV_ALTERNATIVE
	SEV_DEBUGSWAP
	SEV_ES
	SEV_RESTRICTED
	SEV_SNP
	SGX
	SGXLC
	SHA
	SME
	SME_COHERENT
	SPEC_CTRL_SSBD
	SRBDS_CTRL
	SSE
	SSE2
	SSE3
	SSE4
	SSE42
	SSE4A
	SSSE3
	STIBP
	STIBP_ALWAYSON
	STOSB_SHORT
	SUCCOR
	SVM
	SVMDA
	SVMFBASID
	SVML
	SVMNP
	SVMPF
	SVMPFT
	SYSCALL
	SYSEE
	TBM
	TDX_GUEST
	TLB_FLUSH_NESTED
	TME
	TOPEXT
	TSCRATEMSR
	TSXLDTRK
	VAES
	VMCBCLEAN
	VMPL
	VMSA_REGPROT
	VMX
	VPCLMULQDQ
	VTE
	WAITPKG
	WBNOINVD
	WRMSRNS
	X87
	XGETBV1
	XOP
	XSAVE
	XSAVEC
	XSAVEOPT
	XSAVES
	AESARM
	ARM
	ARMCPUID
	ASIMD
	ASIMDDP
	ASIMDHP
	ASIMDRDM
	ATOMICS
	CRC32
	DCPOP
	EVTSTRM
	FCMA
	FP
	FPHP
	GPA
	JSCVT
	LRCPC
	PMULL
	SHA1
	SHA2
	SHA3
	SHA512
	SM3
	SM4
	SVE
	lastID
)

type Vendor int

const (
	VendorUnknown Vendor = iota
	Intel
	AMD
	VIA
	Transmeta
	NSC
	KVM
	MSVM
	VMware
	XenHVM
	Bhyve
	Hygon
	SiS
	RDC
	Ampere
	ARMVendor
	Broadcom
	Cavium
	DEC
	Fujitsu
	Infineon
	Motorola
	NVIDIA
	AMCC
	Qualcomm
	Marvell
	lastVendor
)

type SGXSupport struct {
	Available bool
}

type CPUInfo struct {
	BrandName      string
	VendorID       Vendor
	VendorString   string
	PhysicalCores  int
	ThreadsPerCore int
	LogicalCores    int
	Family         int
	Model          int
	Stepping       int
	CacheLine      int
	Hz             int64
	BoostFreq      int64
	Cache          struct {
		L1I int
		L1D int
		L2  int
		L3  int
	}
	SGX        SGXSupport
	AVX10Level uint8
}

type Features []FeatureID

var CPU CPUInfo

func init() {
	Detect()
}

func Detect() {
	CPU.BrandName = "openharmony-safe-cpuid"
	CPU.VendorID = VendorUnknown
	CPU.VendorString = "unknown"
	CPU.PhysicalCores = 1
	CPU.ThreadsPerCore = 1
	CPU.LogicalCores = 1
	CPU.CacheLine = 64
	CPU.Cache.L1I = 32 << 10
	CPU.Cache.L1D = 32 << 10
	CPU.Cache.L2 = 256 << 10
	CPU.Cache.L3 = -1
}

func DetectARM() {}

func Flags() {}

func CombineFeatures(ids ...FeatureID) Features {
	out := make(Features, len(ids))
	copy(out, ids)
	return out
}

func (c CPUInfo) Supports(ids ...FeatureID) bool { return false }

func (c *CPUInfo) Has(id FeatureID) bool { return false }

func (c CPUInfo) AnyOf(ids ...FeatureID) bool { return false }

func (c *CPUInfo) HasAll(f Features) bool { return false }

func (c CPUInfo) X64Level() int { return 0 }

func (c *CPUInfo) Disable(ids ...FeatureID) bool { return true }

func (c *CPUInfo) Enable(ids ...FeatureID) bool { return true }

func (c CPUInfo) IsVendor(v Vendor) bool { return c.VendorID == v }

func (c CPUInfo) FeatureSet() []string { return nil }

func (c CPUInfo) RTCounter() uint64 { return 0 }

func (c CPUInfo) Ia32TscAux() uint32 { return 0 }

func (c CPUInfo) LogicalCPU() int { return 0 }
