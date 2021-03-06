! Implementing a list of cells:
! In this version the cells in the domain are stored in a list, while the
! occupancy array holds the indices of cells in the list.  When a cell
! leaves the domain or dies a gap is created in the list.
! The locations of such gaps are stored in the gaplist, the total number
! of such gaps is ngaps.  A cell entering the domain is allocated an index
! from the tail of this list, if ngaps > 0, or else it is added to the end of the cell list.

module tropho_mod
use global
use behaviour
!use diffuse
!use ode_diffuse_general
!use ode_diffuse_secretion
!use fields
use winsock

IMPLICIT NONE

contains

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine rng_initialisation
integer, allocatable :: zig_seed(:)
integer :: i, n, R
integer :: kpar = 0
integer :: npar, grainsize = 32

!do i = 1,8
!    my_seed(i) = i
!enddo
!call random_seed(size = m)
!write(*,*) 'random_number seed size: ',m
!my_seed(1:2) = seed(1:2)
!call random_seed(put=my_seed(1:m))

npar = Mnodes
allocate(zig_seed(0:npar-1))
do i = 0,npar-1
    zig_seed(i) = seed(1)*seed(2)*(i+1)
enddo
call par_zigset(npar,zig_seed,grainsize)
par_zig_init = .true.

end subroutine


!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine omp_initialisation(ok)
logical :: ok
integer :: npr, nth

ok = .true.
if (Mnodes == 1) return
!!DEC$ IF ( DEFINED (_OPENMP) .OR. DEFINED (IBM))
#if defined(OPENMP) || defined(_OPENMP)
write(logmsg,'(a,i2)') 'Requested Mnodes: ',Mnodes
call logger(logmsg)
npr = omp_get_num_procs()
write(logmsg,'(a,i2)') 'Machine processors: ',npr
call logger(logmsg)

nth = omp_get_max_threads()
write(logmsg,'(a,i2)') 'Max threads available: ',nth
call logger(logmsg)
if (nth < Mnodes) then
    Mnodes = nth
    write(logmsg,'(a,i2)') 'Setting Mnodes = max thread count: ',nth
	call logger(logmsg)
endif

call omp_set_num_threads(Mnodes)
!$omp parallel
nth = omp_get_num_threads()
write(logmsg,*) 'Threads, max: ',nth,omp_get_max_threads()
call logger(logmsg)
!$omp end parallel
#endif
call logger('did omp_initialisation')
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine array_initialisation(ok)
logical :: ok
integer :: x,y,z,k
integer :: MAXX, z1, z2
real(REAL_KIND) :: d, rr(3)

ok = .false.
call rng_initialisation

nsteps_per_min = 1.0/DELTA_T
if (SIMULATE_2D) then
	NZ = NZ_2D
else
	NZ = NX
endif
ngaps = 0
max_ngaps = 5*NY*NZ
nlist = 0

!allocate(zoffset(0:2*Mnodes))
!allocate(zdomain(NZ))
!allocate(xoffset(0:2*Mnodes))
!allocate(xdomain(NX))
!allocate(zrange2D(NX,NY,2))
!zrange2D = 0
x0 = (NX + 1.0)/2.                ! global value
y0 = (NY + 1.0)/2.
if (SIMULATE_2D) then
	z0 = 1
else
	z0 = (NZ + 1.0)/2.
ENDIF

max_nlist = 1.5*NX*NY*NZ

allocate(occupancy(NX,NY,NZ))
allocate(cell_list(max_nlist))
allocate(gaplist(max_ngaps))

call make_reldir

Centre = (/x0,y0,z0/)   ! now, actually the global centre (units = grids)
lastID = 0
k_nonrandom = 0
lastNTcells = 0
nadd_sites = 0
lastbalancetime = 0

!if (evaluate_residence_time) then
!    allocate(Tres_dist(int(days*24)))
!    Tres_dist = 0
!endif

!if (use_cytokines) then
!    allocate(cytp(NX,NY,NZ,N_CYT))
!endif

#if (0)
if (use_diffusion) then
    if (.not.use_cytokines) then
        write(logmsg,*) 'Cannot use_diffusion without use_cytokines'
	    call logger(logmsg)
        stop
    endif
    allocate(xminmax(NY,NZ,2))
    allocate(inblob(NX,NY,NZ))
    MAXX = 1.5*PI*(NX/2)**3/(2*Mnodes)
    allocate(sitelist(MAXX,3,8))
    allocate(neighbours(0:6,MAXX,8))
endif
#endif

ok = .true.

end subroutine


!--------------------------------------------------------------------------------
!--------------------------------------------------------------------------------
subroutine motility_calibration
integer :: ic,id,k,ds(3), imin,isub
integer :: NTcells, nvar0, nvar, ntime2
integer :: ns = 10000
integer :: npaths = 20
integer :: npos = 301
!integer :: nbeta = 30, nrho = 50
integer :: nbeta = 10, nrho = 10
integer :: ibeta, irho, kpath
real(REAL_KIND) :: dt, time1 = 5, time2 = 15   ! minutes (used for ICB paper results)
real(REAL_KIND) :: tagrad = 10
real(REAL_KIND) :: dbeta, drho
real(REAL_KIND) :: betamin = 0.025, betamax = 0.25		! 0.25 - 0.90 for Model_N, 0.15 - 0.80 for Model_M
real(REAL_KIND) :: rhomin = 0.75, rhomax = 0.95			! 0.20 - 0.85 for Model_N, 0.20 - 0.85 for Model_M
real(REAL_KIND) :: Cm,speed,ssum,d
integer, allocatable :: tagid(:), tagseq(:), tagsite(:,:,:), pathcell(:)
integer, allocatable :: prevsite(:,:)   ! for mean speed computation
real(REAL_KIND), allocatable :: Cm_array(:,:), S_array(:,:)
type(cell_type) :: cell
logical :: ok

write(*,*)
write(*,*) '--------------------'
write(*,*) 'motility_calibration'
write(*,*) '--------------------'

NTcells = NX*NY*NZ
if (motility_save_paths) then
!        allocate(path(3,npaths,0:nvar))
    allocate(pathcell(npaths))
endif

write(*,*) 'Enter range of beta (betamin, betamax):'
read(*,*) betamin,betamax
write(*,*) 'Enter number of beta values:'
read(*,*) nbeta
write(*,*) 'Enter range of rho (rhomin, rhomax):'
read(*,*) rhomin,rhomax
write(*,*) 'Enter number of rho values:'
read(*,*) nrho
write(*,*)

time2 = 420

ntime2 = time2
nvar0 = time1
nvar = time2    ! number of minutes to simulate
dt = DELTA_T*nsteps_per_min
TagRadius = tagrad

if (motility_param_range) then
	drho = (rhomax-rhomin)/(nrho-1)
	dbeta = (betamax-betamin)/(nbeta-1)
elseif (n_multiple_runs > 1) then
	nbeta = n_multiple_runs
	nrho = 1
	betamin = beta
	rhomin = rho
	drho = 0
	dbeta = 0
else
	nbeta = 1
	nrho = 1
	betamin = beta
	rhomin = rho
	drho = 0
	dbeta = 0
endif

allocate(Cm_array(nrho,nbeta))
allocate(S_array(nrho,nbeta))

write(*,*) 'nbeta,nrho: ',nbeta,nrho
do ibeta = 1,nbeta
    do irho = 1,nrho
	    rho = rhomin + (irho-1)*drho
	    beta = betamin + (ibeta-1)*dbeta
	    write(*,'(a,2i3,2f6.2)') ' beta, rho: ',ibeta,irho,BETA,RHO
	    call compute_dirprobs
	    call PlaceCells(ok)
	    if (.not.ok) stop
        if (nlist > 0) then
!	        write(*,*) 'make tag list: NTcells,nlist,ntagged: ',NTcells,nlist,ntagged

            allocate(tagseq(NTcells))
            allocate(tagid(ntagged))
            allocate(tagsite(3,ntagged,0:nvar))
            tagseq = 0
            k = 0
	        kpath = 0
            do ic = 1,nlist
                if (cell_list(ic)%tag == TAGGED_CELL) then
                    id = cell_list(ic)%ID
                    k = k+1
                    tagid(k) = id
                    tagseq(id) = k
                    tagsite(:,k,0) = cell_list(ic)%site
					if (motility_save_paths) then
						if (kpath < npaths) then
							kpath = kpath + 1
							pathcell(kpath) = ic
						endif
					endif
                endif
            enddo
        endif

		if (ibeta == 1 .and. irho == 1) then
	        ns = min(ns,nlist)
		    allocate(prevsite(3,ns))
		endif
        do ic = 1,ns
            prevsite(:,ic) = cell_list(ic)%site
        enddo
        ssum = 0

        !
        ! Now we are ready to run the simulation
        !
        if (motility_save_paths) then
            open(nfpath,file='path.out',status='replace')
            write(nfpath,'(i3,a)') npaths,' paths'
        endif

		istep = 0
        do imin = 1,nvar
            do isub = 1,nsteps_per_min
				istep = istep + 1
                call mover(ok)
                if (.not.ok) stop
!                if (.not.SIMULATE_2D) then
!	                call squeezer(.false.)
!	            endif
                do ic = 1,ns
                    ds = cell_list(ic)%site - prevsite(:,ic)
                    prevsite(:,ic) = cell_list(ic)%site
                    d = sqrt(real(ds(1)*ds(1) + ds(2)*ds(2) + ds(3)*ds(3)))
                    ssum = ssum + d*DELTA_X/DELTA_T
                enddo
                if (motility_save_paths) then
                    k = (imin-1)*nsteps_per_min + isub
                    if (k >= nvar0*nsteps_per_min .and. k < nvar0*nsteps_per_min + npos) then
                        write(nfpath,'(160i4)') (cell_list(pathcell(kpath))%site(1:2),kpath=1,npaths)
                    endif
                endif
            enddo
!            write(*,*) 'speed: ',ssum/(ns*nsteps_per_min*imin)

            do ic = 1,nlist
                cell = cell_list(ic)
                if (cell%tag == TAGGED_CELL) then
                    id = cell%ID
                    k = tagseq(id)
                    tagsite(:,k,imin) = cell%site
                endif
            enddo
        enddo
        call compute_Cm(tagsite,ntagged,nvar0,nvar,dt,Cm)
        speed = ssum/(ns*nvar*nsteps_per_min)
        write(*,'(a,2f8.2)') 'speed, Cm: ',speed,Cm
        write(nfout,'(a,4f8.3)') 'beta, rho, speed, Cm: ',beta,rho,speed,Cm
        if (allocated(tagid))   deallocate(tagid)
        if (allocated(tagseq))  deallocate(tagseq)
        if (allocated(tagsite)) deallocate(tagsite)
	enddo
enddo
if (allocated(pathcell)) deallocate(pathcell)
deallocate(Cm_array)
deallocate(S_array)
if (motility_save_paths) then
    close(nfpath)
endif

end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine diffusion_calibration
!!!use ifport
integer :: x, y, z, istep
integer, parameter :: Ntimes = 50   !500
real(REAL_KIND) :: t1, t2, Cnumeric(Ntimes),Canalytic(Ntimes)
logical :: ok

write(*,*) 'diffusion_calibration: '
!call init_cytokine

x = NX/4
call analytical_soln(x,Canalytic,Ntimes)
call PlaceCells(ok)
if (.not.ok) stop
!call make_split(.true.)

!t1 = timef()
call cpu_time(t1)
do x = 1,NX
    do y = 1,NY
        do z = 1,NZ
            occupancy(x,y,z)%indx = 1
        enddo
    enddo
enddo

!do istep = 1,Ntimes
!    call diffuser
!    write(*,*) istep,cyt(NX/4,NY/2,NZ/2,1)
!    Cnumeric(istep) = cyt(NX/4,NY/2,NZ/2,1)
!enddo
!t2 = timef()
call cpu_time(t2)
write(*,'(a,f10.2)') 'Time: ',t2-t1
write(nfout,*) 'NX, x, NDIFFSTEPS: ',NX,x,NDIFFSTEPS
do istep = 1,Ntimes
    write(nfout,'(i6,f8.2,2f8.4)') istep,istep*DELTA_T,Cnumeric(istep),Canalytic(istep)
enddo

call wrapup
stop

end subroutine

!-----------------------------------------------------------------------------------------
! A(n) = 2*Int[0,L](C0(x).cos(n.pi.x/L).dx)
! with C0(x) = 1  x < L/2
!            = 0  x > L/2
! L = NX*DX
! Site i corresponds to x = (i - 1/2)DX
! With n = 2m-1, the integral for A gives for m = 1,2,3,...:
! B(m) = A(n) = (-1)^m.2/(pi*n), other A(n) = 0
! and B(0) = 0.5
! and solution is the series:
! C(x,t) = B(0) + Sum[m=1,...] B(m).cos(n.pi.x/L).exp(-K.t.(n*pi/L)^2)
!-----------------------------------------------------------------------------------------
subroutine analytical_soln(xsite,C,Ntimes)
integer :: xsite, Ntimes
real(REAL_KIND) :: C(Ntimes)
integer, parameter :: Nterms = 100
real(REAL_KIND) :: DX, DT, x, t, csum, bsum, L, xL, Kdiff, dC, tfac, Kfac, B(0:Nterms)
integer :: n, m, k

!Kdiff = K_diff(1)
Kdiff = 2.0e-12         ! m^2/s
write(*,*) 'DELTA_T: ',DELTA_T, DELTA_X, PI, Kdiff
DX = DELTA_X*1.0e-6     ! m
DT = DELTA_T*60         ! s
L = NX*DX
B(0) = 0.5d0
bsum = 0
do m = 1,Nterms
    n = 2*m-1
    B(m) = ((-1)**(m+1))*2/(n*PI)
!    B1 = (2/(n*PI))*sin(n*PI/2)
!    write(*,*) m,n,B(m)-B1
    bsum = bsum + B(m)
enddo

Kfac = Kdiff*PI*PI/(L*L)
write(*,*) 'Bsum: ',B(0),bsum
x = (xsite-0.5)*DX
xL = PI*x/L
do k = 1,Ntimes
    t = k*DT
    csum = B(0)
    do m = 1,Nterms
        n = 2*m-1
        tfac = exp(-Kfac*n*n*t)
        dC = B(m)*cos(n*xL)*tfac
        csum = csum + dC
!        write(*,'(2i4,3e12.4)') m,n,tfac,dC,csum
    enddo
    C(k) = csum
enddo
write(*,'(10f7.4)') C
!write(nfout,*) 'Analytical solution'
!write(nfout,'(10f7.4)') C
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
real(REAL_KIND) function hill(x,b,n)
real(REAL_KIND) :: x, b
integer :: n
hill = x**n/(x**n + b**n)
end function

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine testqsort(n)
integer :: n
integer :: i
integer :: kpar = 0
real(REAL_KIND), allocatable :: a(:)
integer, allocatable :: t(:)

call rng_initialisation

allocate(a(n))
allocate(t(n))
do i = 1,n
    a(i) = par_uni(kpar)
    t(i) = i
enddo
call qsort(a,n,t)
end subroutine


!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine testrnor
integer :: n = 100000
integer :: k, j
integer :: kpar = 0
real(REAL_KIND) :: r, rmin=1.0e10, rmax = -1.0e10

do k = 1,n
    do j = 1,n
        r = par_rnor(kpar)
        rmin = min(r,rmin)
        rmax = max(r,rmax)
    enddo
    write(*,'(i12,2e12.4)') k,rmin,rmax
enddo
end subroutine


!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine save_positions
integer :: kcell, site(3)

write(nflog,'(i6,$)') istep
do kcell = 1,n_cell_positions
    site = cell_list(kcell)%site
    write(nflog,'(2i5,$)') site(1:2)
enddo
write(nflog,*)
end subroutine

!-----------------------------------------------------------------------------------------
! Various logging counters are initialized here.
!-----------------------------------------------------------------------------------------
subroutine init_counters

ninflow_tag = 0
noutflow_tag = 0
!call init_counter(DCtraveltime_count,200,0.0,1.0,.false.)

end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine test_cum_prob
real(REAL_KIND) :: m = 30, s = 2.0
real(REAL_KIND) :: p1, p2, a
integer :: i

p1 = log(m)
p2 = log(s)
do i = 1,30
    a = 2*i
    write(*,'(i4,2f8.3)') i,a,1-cum_prob_lognormal(a,p1,p2)
enddo
end subroutine

!--------------------------------------------------------------------------------
!--------------------------------------------------------------------------------
subroutine get_dimensions(NX_dim,NY_dim,NZ_dim) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_dimensions
use, intrinsic :: iso_c_binding
integer(c_int) :: NX_dim,NY_dim,NZ_dim

NX_dim = NX
NY_dim = NY
NZ_dim = NZ
end subroutine

!-----------------------------------------------------------------------------------------
! Using the complete list of cells, cell_list(), extract info about the current state of the
! paracortex.  This info must be supplemented by counts of cells that have died and cells that
! have returned to the circulation.
! We now store stim() and IL2sig() for cells in the periphery.
!-----------------------------------------------------------------------------------------
subroutine get_summary(summaryData) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_summary
use, intrinsic :: iso_c_binding
integer(c_int) :: summaryData(*)
logical :: ok

if (.not.use_TCP) then
!write(*,'(a)') '----------------------------------------------------------------------'
!write(*,'(a,i6,5i8,a,2i8)') 'snapshot: ',istep
!write(*,'(a)') '----------------------------------------------------------------------'
endif

summaryData(1:2) = [ istep, NTcells ]
!summaryData(1:26) = (/ int(tnow/60), istep, NDCalive, ntot_LN, nseed, ncog(1), ncog(2), ndead, &
!	nbnd, int(InflowTotal), Nexits, nteffgen0, nteffgen,   nact, navestim(1), navestim(2), navestimrate(1), &
!	navefirstDCtime, naveDCtraveltime, naveDCbindtime, nbndfraction, nDCSOI, &
!	noDCcontactfraction, int(noDCcontacttime), int(avetotalDCtime(1)), int(avetotalDCtime(2)) /)

!write(nfout,'(f10.2,12i10,$)') tnow/60, istep, ntot_LN
!write(nfout,*)
!
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine write_header
write(nfout,'(a)') '================================================================================================================'
write(nfout,*)
write(nfout,'(a10,$)') '      Hour'
write(nfout,'(a10,$)') '  Timestep'
write(nfout,'(a10,$)') '  N_Tcells'
write(nfout,*)
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine get_nFACS(n) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_nfacs
use, intrinsic :: iso_c_binding
integer(c_int) :: n
integer :: k, kcell, region
!type (cog_type), pointer :: p

!n = 0
!do k = 1,lastcogID
!    kcell = cognate_list(k)
!    if (kcell == 0) cycle
!    p => cell_list(kcell)%cptr
!	call get_region(p,region)
!	n = n+1
!enddo
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine get_FACS(facs_data) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_facs
use, intrinsic :: iso_c_binding
real(c_double) :: facs_data(*)
integer :: i, k, kcell, region
!type (cog_type), pointer :: p

!k = 0
!do i = 1,lastcogID
!    kcell = cognate_list(i)
!    if (kcell == 0) cycle
!    p => cell_list(kcell)%cptr
!	call get_region(p,region)
!	k = k+1
!	facs_data(k) = p%CFSE
!	k = k+1
!	facs_data(k) = p%CD69
!	k = k+1
!	facs_data(k) = p%S1PR1
!	k = k+1
!	facs_data(k) = p%avidity
!	k = k+1
!	facs_data(k) = p%stimulation
!enddo
end subroutine

!--------------------------------------------------------------------------------
! x, y, z, gen, CFSE, CD69, S1PR1, stim, stimrate
!--------------------------------------------------------------------------------
subroutine write_FACS(hour)	!bind(C)	!(filename)
!!DEC$ ATTRIBUTES DLLEXPORT :: write_facs
integer :: hour
character(14) :: filename
!type (cog_type), pointer :: p
integer :: k, kcell, region, gen, site(3)

filename = 'FACS_h0000.dat'
write(filename(7:10),'(i0.4)') hour
open(nffacs, file=filename, status='replace')
!do k = 1,lastcogID
!    kcell = cognate_list(k)
!    if (kcell == 0) cycle
!    p => cell_list(kcell)%cptr
!	call get_region(p,region)
!	gen = get_generation(p)
!	site = cell_list(kcell)%site
!	write(nffacs,'(i3,a,$)') site(1),', '
!	write(nffacs,'(i3,a,$)') site(2),', '
!	write(nffacs,'(i3,a,$)') site(3),', '
!	write(nffacs,'(i3,a,$)') gen,', '
!	write(nffacs,'(e12.4,a,$)') p%CFSE,', '
!	write(nffacs,'(f7.4,a,$)') p%CD69,', '
!	write(nffacs,'(f7.4,a,$)') p%S1PR1,', '
!	write(nffacs,*)
!enddo
close(nffacs)
end subroutine

!-----------------------------------------------------------------------------------------
! nhisto is the number of histogram boxes
! vmin(ivar),vmax(ivar) are the minimum,maximums value for variable ivar
!
! Compute 3 distributions: 1 = both cell types
!                          2 = type 1
!                          3 = type 2
! Stack three cases in vmax() and histo_data()
!
! No, for tropho assume just a single cell type, but leave code in place for multiple cell types.
! For now there are just two variables:
!   distance from starting position
!   angle in degrees made by total displacement vector
!-----------------------------------------------------------------------------------------
subroutine get_histo(nhisto, histo_data, vmin, vmax, histo_data_log, vmin_log, vmax_log) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_histo
use, intrinsic :: iso_c_binding
integer(c_int),value :: nhisto
real(c_double) :: vmin(*), vmax(*), histo_data(*)
real(c_double) :: vmin_log(*), vmax_log(*), histo_data_log(*)
real(REAL_KIND) :: val, val_log, dx, dy
integer :: n(3), i, ih, k, kcell, ict, ichemo, ivar, nvars, var_index(32), nct
integer,allocatable :: cnt(:,:,:)
real(REAL_KIND),allocatable :: dv(:,:), valmin(:,:), valmax(:,:)
integer,allocatable :: cnt_log(:,:,:)
real(REAL_KIND),allocatable :: dv_log(:,:), valmin_log(:,:), valmax_log(:,:)

!write(nflog,*) 'get_histo'
nct = 1	! number of cell types
nvars = 2

allocate(cnt(nct,nvars,nhisto))
allocate(dv(nct,nvars))
allocate(valmin(nct,nvars))
allocate(valmax(nct,nvars))
allocate(cnt_log(nct,nvars,nhisto))
allocate(dv_log(nct,nvars))
allocate(valmin_log(nct,nvars))
allocate(valmax_log(nct,nvars))
cnt = 0
valmin = 0
valmax = -1.0e10
cnt_log = 0
valmin_log = 1.0e10
valmax_log = -1.0e10
n = 0
do kcell = 1,nlist
!	if (cell_list(kcell)%state == DEAD) cycle
!	ict = cell_list(kcell)%celltype
	ict = 1
	dx = cell_list(kcell)%dtotal(1)
	dy = cell_list(kcell)%dtotal(2)
!	write(nflog,*) kcell,dx,dy
	do ivar = 1,nvars
		if (ivar == 1) then
			val = sqrt(dx*dx + dy*dy)
		elseif (ivar == 2) then
			val = atan2(dy,dx)*180/PI
		endif
!		valmax(ict+1,ivar) = max(valmax(ict+1,ivar),val)	! cell type 1 or 2
		valmax(1,ivar) = max(valmax(1,ivar),val)			! both
		if (val <= 1.0e-8) then
			val_log = -8
		else
			val_log = log10(val)
		endif
!		valmin_log(ict+1,ivar) = min(valmin_log(ict+1,ivar),val_log)	! cell type 1 or 2
		valmin_log(1,ivar) = min(valmin_log(1,ivar),val_log)			! both
!		valmax_log(ict+1,ivar) = max(valmax_log(ict+1,ivar),val_log)	! cell type 1 or 2
		valmax_log(1,ivar) = max(valmax_log(1,ivar),val_log)			! both
	enddo
!	n(ict+1) = n(ict+1) + 1
	n(1) = n(1) + 1
enddo

dv = (valmax - valmin)/nhisto
!write(nflog,*) 'dv'
!write(nflog,'(e12.3)') dv
dv_log = (valmax_log - valmin_log)/nhisto
!write(nflog,*) 'dv_log'
!write(nflog,'(e12.3)') dv_log
do kcell = 1,nlist
!	if (cell_list(kcell)%state == DEAD) cycle
!	ict = cell_list(kcell)%celltype
	ict = 1
	dx = cell_list(kcell)%dtotal(1)
	dy = cell_list(kcell)%dtotal(2)
	do ivar = 1,nvars
		if (ivar == 1) then
			val = sqrt(dx*dx + dy*dy)
		elseif (ivar == 2) then
			val = atan2(dy,dx)*180/PI
		endif
		k = (val-valmin(1,ivar))/dv(1,ivar) + 1
		k = min(k,nhisto)
		k = max(k,1)
		cnt(1,ivar,k) = cnt(1,ivar,k) + 1
!		k = (val-valmin(ict+1,ivar))/dv(ict+1,ivar) + 1
!		k = min(k,nhisto)
!		k = max(k,1)
!		cnt(ict+1,ivar,k) = cnt(ict+1,ivar,k) + 1
		if (val <= 1.0e-8) then
			val_log = -8
		else
			val_log = log10(val)
		endif
		k = (val_log-valmin_log(1,ivar))/dv_log(1,ivar) + 1
		k = min(k,nhisto)
		k = max(k,1)
		cnt_log(1,ivar,k) = cnt_log(1,ivar,k) + 1
!		k = (val_log-valmin_log(ict+1,ivar))/dv_log(ict+1,ivar) + 1
!		k = min(k,nhisto)
!		k = max(k,1)
!		cnt_log(ict+1,ivar,k) = cnt_log(ict+1,ivar,k) + 1
	enddo
enddo

do i = 1,1
	if (n(i) == 0) then
		vmin((i-1)*nvars+1:i*nvars) = 0
		vmax((i-1)*nvars+1:i*nvars) = 0
		histo_data((i-1)*nvars*nhisto+1:i*nhisto*nvars) = 0
		vmin_log((i-1)*nvars+1:i*nvars) = 0
		vmax_log((i-1)*nvars+1:i*nvars) = 0
		histo_data_log((i-1)*nvars*nhisto+1:i*nhisto*nvars) = 0
	else
		do ivar = 1,nvars
			vmin((i-1)*nvars+ivar) = valmin(i,ivar)
			vmax((i-1)*nvars+ivar) = valmax(i,ivar)
			do ih = 1,nhisto
				k = (i-1)*nvars*nhisto + (ivar-1)*nhisto + ih
				histo_data(k) = (100.*cnt(i,ivar,ih))/n(i)
			enddo
			vmin_log((i-1)*nvars+ivar) = valmin_log(i,ivar)
			vmax_log((i-1)*nvars+ivar) = valmax_log(i,ivar)
			do ih = 1,nhisto
				k = (i-1)*nvars*nhisto + (ivar-1)*nhisto + ih
				histo_data_log(k) = (100.*cnt_log(i,ivar,ih))/n(i)
			enddo
		enddo
	endif
enddo
deallocate(cnt)
deallocate(dv)
deallocate(valmin)
deallocate(valmax)
deallocate(cnt_log)
deallocate(dv_log)
deallocate(valmin_log)
deallocate(valmax_log)
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine get_constituents(nvars,cvar_index,nvarlen,name_array,narraylen) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_constituents
use, intrinsic :: iso_c_binding
character(c_char) :: name_array(0:*)
integer(c_int) :: nvars, cvar_index(0:*), nvarlen, narraylen
integer :: ivar, k
character*(24) :: name
character(c_char) :: c

write(nflog,*) 'get_constituents'
nvarlen = 12
ivar = 0
k = ivar*nvarlen
cvar_index(ivar) = 0
name = 'Distance'
call copyname(name,name_array(k),nvarlen)
ivar = ivar + 1
k = ivar*nvarlen
cvar_index(ivar) = 1
name = 'Angle'
call copyname(name,name_array(k),nvarlen)
nvars = ivar + 1
write(nflog,*) 'did get_constituents'
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine copyname(name,name_array,n)
character*(*) :: name
character :: name_array(*)
integer :: n
integer :: k

do k = 1,n
	name_array(k) = name(k:k)
enddo
end subroutine


!--------------------------------------------------------------------------------
! Pass a list of cell positions and associated data
!--------------------------------------------------------------------------------
subroutine get_scene(nTC_list,TC_list) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: get_scene
use, intrinsic :: iso_c_binding
integer(c_int) :: nTC_list, TC_list(*)
integer :: k, kcell, j, site(3)
integer :: itcstate, ctype

! T cell section
k = 0
do kcell = 1,nlist
	if (cell_list(kcell)%ID == 0) cycle  ! gap
	k = k+1
	j = 5*(k-1)
	site = cell_list(kcell)%site
!	ctype = cell_list(kcell)%ctype
	itcstate = 0
	TC_list(j+1) = kcell-1
	TC_list(j+2:j+4) = site
	TC_list(j+5) = itcstate
enddo
nTC_list = k
end subroutine

!-----------------------------------------------------------------------------------------
! Now this is used only to set use_TCP = .false.
! The lines
!    call get_command (b, len, status)
!    call get_command_argument (0, c, len, status)
! were failing with gfortran (don't know why), but in any case there was no need to
! get the command line arguments in this way.
!-----------------------------------------------------------------------------------------
subroutine process_command_line(ncpu,infile,outfile)
!DEC$ ATTRIBUTES DLLEXPORT :: process_command_line
!DEC$ ATTRIBUTES STDCALL, REFERENCE, MIXED_STR_LEN_ARG, ALIAS:"PROCESS_COMMAND_LINE" :: process_command_line
integer :: i, cnt, len, status
integer :: ncpu
character :: c*(64), b*(256)
character*(64) :: infile,outfile
character*(64) :: progname

!write(*,*) 'process_command_line'
use_TCP = .false.   ! because this is called from para_main()							! --> use_TCP

return

ncpu = 3
infile = 'omp_para.inp'
outfile = 'omp_para.out'
!resfile = 'result.out'
!runfile = ' '

call get_command (b, len, status)
if (status .ne. 0) then
    write (logmsg,'(a,i4)') 'get_command failed with status = ', status
    call logger(logmsg)
    stop
end if
call logger('command: ')
call logger(b)
c = ''
call get_command_argument (0, c, len, status)
if (status .ne. 0) then
    write (*,*) 'Getting command name failed with status = ', status
    write(*,*) c
    stop
end if
progname = c(1:len)
cnt = command_argument_count ()
if (cnt < 1) then
    write(*,*) 'Use: ',trim(progname),' num_cpu'
    stop
endif

do i = 1, cnt
    call get_command_argument (i, c, len, status)
    if (status .ne. 0) then
        write (*,*) 'get_command_argument failed: status = ', status, ' arg = ', i
        stop
    end if
    if (i == 1) then
!        read(c(1:len),'(i)') ncpu
        read(c(1:len),*) ncpu															! --> ncpu
        write(*,*) 'Requested threads: ',ncpu
    elseif (i == 2) then
        infile = c(1:len)																! --> infile
        write(*,*) 'Input file: ',infile
    elseif (i == 3) then
        outfile = c(1:len)																! --> outfile
        write(*,*) 'Output file: ',outfile
    endif
end do

end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine simulate_step(res) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: simulate_step
use, intrinsic :: iso_c_binding
integer(c_int) :: res
integer :: hour, kpar=0
real(REAL_KIND) :: tnow
logical :: ok

res = 0
dbug = .false.
ok = .true.
istep = istep + 1
if (n_cell_positions > 0) then
	call save_positions
endif
tnow = istep*DELTA_T
if (mod(istep,240) == 0) then
	write(logmsg,*) 'simulate_step: ',istep
	call logger(logmsg)
    if (TAGGED_LOG_PATHS) then
		call add_log_paths
	endif
!	call checker
!	call checker2D
endif
!if (FACS_INTERVAL > 0) then
!	if (mod(istep,FACS_INTERVAL*240) == 0) then
!		hour = istep/240
!		call write_FACS(hour)
!	endif
!endif
if (TAGGED_LOG_PATHS .and. mod(istep,1) == 0) then
	call update_log_paths
endif
!if (use_cytokines) then
!    call diffuser
!endif

call mover(ok)
if (.not.ok) then
	call logger("mover returned error")
	res = -1
	return
endif

end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine connection(awp,port,error)
TYPE(winsockport) :: awp
integer :: port, error
integer :: address = 0
!!!character*(64) :: ip_address = "127.0.0.1"C      ! need a portable way to make a null-terminated C string
character*(64) :: host_name = "localhost"

if (.not.winsock_init(1)) then
    call logger("winsock_init failed")
    stop
endif

awp%handle = 0
awp%host_name = host_name
awp%ip_port = port
awp%protocol = IPPROTO_TCP
call Set_Winsock_Port (awp,error)

if (.not.awp%is_open) then
    write(nflog,*) 'Error: connection: awp not open: ',port
endif
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine connecter(ok)
logical :: ok
integer :: error

! Main connection
ok = .true.
call connection(awp_0,TCP_PORT_0,error)
if (awp_0%handle < 0 .or. error /= 0) then
    write(logmsg,'(a)') 'TCP connection to TCP_PORT_0 failed'
    call logger(logmsg)
    ok = .false.
    return
endif
if (.not.awp_0%is_open) then
	write(logmsg,'(a)') 'No connection to TCP_PORT_0'
    call logger(logmsg)
    ok = .false.
    return
endif
write(logmsg,'(a)') 'Connected to TCP_PORT_0  '
call logger(logmsg)

if (use_CPORT1) then
	call connection(awp_1,TCP_PORT_1,error)
	if (awp_1%handle < 0 .or. error /= 0) then
		write(logmsg,'(a)') 'TCP connection to TCP_PORT_1 failed'
		call logger(logmsg)
		ok = .false.
		return
	endif
	if (.not.awp_1%is_open) then
		write(logmsg,'(a)') 'No connection to TCP_PORT_1'
		call logger(logmsg)
		ok = .false.
		return
	endif
	write(logmsg,'(a)') 'Connected to TCP_PORT_1  '
	call logger(logmsg)
endif
! Allow time for completion of the connection
call sleeper(2)
end subroutine



!-----------------------------------------------------------------------------------------
! This subroutine is called to initialize a simulation run.
! ncpu = the number of processors to use
! infile = file with the input data
! outfile = file to hold the output
! runfile = file to pass info to the master program (e.g. Python) as the program executes.
!-----------------------------------------------------------------------------------------
subroutine setup(ncpu,infile,outfile,ok)
integer :: ncpu
character*(*) :: infile, outfile
logical :: ok
character*(64) :: msg
integer :: error

ok = .true.
initialized = .false.
par_zig_init = .false.
!Mnodes = ncpu
Mnodes = 1
inputfile = infile
outputfile = outfile
write(logmsg,*) 'ncpu: ',Mnodes
call logger(logmsg)

#if defined(OPENMP) || defined(_OPENMP)
    call logger("OPENMP defined")
    call omp_initialisation(ok)
    if (.not.ok) return
#else
    call logger("OPENMP NOT defined")
    if (Mnodes > 1) then
        write(logmsg,'(a)') 'No OpenMP, using one thread only'
        call logger(logmsg)
        Mnodes = 1
    endif
#endif

call logger("read_cell_params")
call read_cell_params(ok)
if (.not.ok) return
call logger("did read_cell_params")

call array_initialisation(ok)
if (.not.ok) return
call logger('did array_initialisation')

if (calibrate_motility) then
	call motility_calibration
	stop
endif

call PlaceCells(ok)
if (ok) then
	call logger('did PlaceCells: OK')
else
	call logger('did PlaceCells: not OK')
	stop
endif
if (.not.ok) return


!call make_split(.true.)
call init_counters
if (TAGGED_LOG_PATHS) then
	call setup_log_path_sites
endif
if (save_input) then
    call save_inputfile(inputfile)
!	call save_inputfile(fixedfile)
    call save_parameters
    call write_header
endif
call chemokine_setup
firstSummary = .true.
initialized = .true.
write(logmsg,'(a,i6)') 'Startup procedures have been executed: initial T cell count: ',NTcells0
call logger(logmsg)

end subroutine

!-----------------------------------------------------------------------------------------
! The test case has two chemokines and two associated receptor types.
! Each receptor has the same strength.  The difference in the effects of the two
! chemokine-receptor pairs is determined by the chemokine gradient parameters.
!-----------------------------------------------------------------------------------------
subroutine chemokine_setup
integer :: x, y, z, kcell
real(REAL_KIND) :: rad, g(3)
type(cell_type), pointer :: cell

call chemo_p_setup

! Set up a test case.

! Chemokines
!===========
! Instead of solving for the chemokine concentrations, the chemokine gradient is specified.
chemo(1)%name = 'Chemokine_1'
if (chemo(1)%used) then
	if (allocated(chemo(1)%grad)) deallocate(chemo(1)%grad)
	allocate(chemo(1)%grad(3,NX,NY,NZ))
	rad = grad_dir(1)*PI/180
	g(1) = grad_amp(1)*cos(rad)
	g(2) = grad_amp(1)*sin(rad)
	g(3) = 0
	do x = 1,NX
		do y = 1,NY
			do z = 1,NZ
				chemo(1)%grad(:,x,y,z) = g(:)
			enddo
		enddo
	enddo
endif
chemo(2)%name = 'Chemokine_2'
if (chemo(2)%used) then
	if (allocated(chemo(2)%grad)) deallocate(chemo(2)%grad)
	allocate(chemo(2)%grad(3,NX,NY,NZ))
	rad =  grad_dir(2)*PI/180
	g(1) = grad_amp(2)*cos(rad)
	g(2) = grad_amp(2)*sin(rad)
	g(3) = 0
	do x = 1,NX
		do y = 1,NY
			do z = 1,NZ
				chemo(2)%grad(:,x,y,z) = g(:)
			enddo
		enddo
	enddo
endif

! Receptors
!==========
receptor(1)%name = 'Receptor_1'
receptor(1)%chemokine = 1
receptor(1)%used = chemo(receptor(1)%chemokine)%used
receptor(1)%sign = 1
receptor(1)%strength = 1.0
receptor(2)%name = 'Receptor_2'
receptor(2)%used = .false.
receptor(2)%chemokine = 2
receptor(2)%used = chemo(receptor(2)%chemokine)%used
receptor(2)%sign = 1
receptor(2)%strength = 1.0

! Cells
!======
do kcell = 1,nlist
	cell => cell_list(kcell)
	cell%receptor_saturation_time = 0
	cell%receptor_level(1) = 1
	cell%receptor_level(2) = 1
enddo
end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine wrapup
integer :: ic, ierr
logical :: isopen

call logger('doing wrapup ...')
ierr = 0
!if (allocated(xoffset)) deallocate(xoffset)
!if (allocated(zoffset)) deallocate(zoffset)
!if (allocated(xdomain)) deallocate(xdomain)
!if (allocated(zdomain)) deallocate(zdomain)
!if (allocated(zrange2D)) deallocate(zrange2D)
if (allocated(occupancy)) deallocate(occupancy)
!if (allocated(Tres_dist)) deallocate(Tres_dist)
if (allocated(cell_list)) deallocate(cell_list,stat=ierr)
if (ierr /= 0) then
    write(*,*) 'cellist deallocate error: ',ierr
    stop
endif
ierr = 0
if (allocated(gaplist)) deallocate(gaplist,stat=ierr)
if (allocated(life_dist)) deallocate(life_dist)
if (allocated(divide_dist)) deallocate(divide_dist)
if (allocated(chemo_p)) deallocate(chemo_p)

#if (0)
if (allocated(cytp)) deallocate(cytp)
if (allocated(xminmax)) deallocate(xminmax)
if (allocated(inblob)) deallocate(inblob)
if (allocated(sitelist)) deallocate(sitelist)
if (allocated(neighbours)) deallocate(neighbours)
do ic = 1,MAX_CHEMO
	if (allocated(chemo(ic)%conc)) then
		deallocate(chemo(ic)%conc)
		deallocate(chemo(ic)%grad)
	endif
enddo
if (allocated(ODEdiff%ivar)) then
	deallocate(ODEdiff%ivar)
	deallocate(ODEdiff%varsite)
	deallocate(ODEdiff%icoef)
endif
#endif

! Close all open files
inquire(unit=nfout,OPENED=isopen)
if (isopen) then
	close(nfout)
	call logger('closed nfout')
endif
inquire(nfres,OPENED=isopen)
if (isopen) close(nfres)
inquire(nftraffic,OPENED=isopen)
if (isopen) close(nftraffic)
inquire(nfchemo,OPENED=isopen)
if (isopen) close(nfchemo)

if (par_zig_init) then
	call par_zigfree
endif

end subroutine

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine terminate_run(res) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: terminate_run
use, intrinsic :: iso_c_binding
integer(c_int) :: res
character*(8), parameter :: quit = '__EXIT__'
integer :: error, i

!call SaveGenDist
!if (evaluate_residence_time) then
!	call write_Tres_dist
!endif
if (TAGGED_LOG_PATHS) then
	call write_log_paths
endif
!call write_FACS

call wrapup

if (res == 0) then
	call logger(' Execution successful!')
else
	call logger('  === Execution failed ===')
	call sleeper(1)
endif

if (use_TCP) then
	if (stopped) then
	    call winsock_close(awp_0)
	    if (use_CPORT1) call winsock_close(awp_1)
	else
	    call winsock_send(awp_0,quit,8,error)
	    call winsock_close(awp_0)
!	    call logger("closed PORT_0")
		if (use_CPORT1) then
			call winsock_send(awp_1,quit,8,error)
			call winsock_close(awp_1)
!			call logger("closed PORT_1")
		endif
	endif
endif

end subroutine

!-----------------------------------------------------------------------------------------
! This is the DLL procedure that can be called from an external non-Fortran program to
! make a simulation run.
! Called from Python with:
!     mydll.EXECUTE(byref(ncpu),infile,n1,outfile,n2,resfile,n3,runfile,n4)
! Note that the arguments n1,n2,n3,n4, the lengths of the filename strings, are
! hidden arguments (they are not explicitly in the Fortran subroutine argument list).
! Every Python string needs to be followed by a hidden length parameter, and unless
! the declared length of a Fortran string matches the actual length of that passed from
! Python, the form character*(*) must be used.
!-----------------------------------------------------------------------------------------
subroutine execute(ncpu,infile_array,inbuflen,outfile_array,outbuflen) BIND(C)
!DEC$ ATTRIBUTES DLLEXPORT :: execute
use, intrinsic :: iso_c_binding
character(c_char) :: infile_array(128), outfile_array(128)
integer(c_int) :: ncpu, inbuflen, outbuflen
character*(128) :: infile, outfile
logical :: ok, success, isopen
integer :: i, res

use_CPORT1 = .false.	! DIRECT CALLING FROM Fortran, C++
infile = ''
do i = 1,inbuflen
	infile(i:i) = infile_array(i)
enddo
outfile = ''
do i = 1,outbuflen
	outfile(i:i) = outfile_array(i)
enddo

inquire(unit=nflog,OPENED=isopen)
if (.not.isopen) then
    open(nflog,file='tropho.log',status='replace')
endif
awp_0%is_open = .false.
awp_1%is_open = .false.

#ifdef GFORTRAN
    write(logmsg,'(a)') 'Built with GFORTRAN'
	call logger(logmsg)
#endif

logmsg = 'OS??'
#ifdef LINUX
    write(logmsg,'(a)') 'OS is Linux'
#endif
#ifdef OSX
    write(logmsg,'(a)') 'OS is OS-X'
#endif
#ifdef _WIN32
    write(logmsg,'(a)') 'OS is Windows'
#endif
#ifdef WINDOWS
    write(logmsg,'(a)') 'OS is Windows'
#endif
call logger(logmsg)

!#ifdef OPENMP
#if defined(OPENMP) || defined(_OPENMP)
    write(logmsg,'(a)') 'Executing with OpenMP'
	call logger(logmsg)
#endif

write(logmsg,*) 'inputfile:  ', infile
call logger(logmsg)
write(logmsg,*) 'outputfile: ', outfile
call logger(logmsg)
if (use_tcp) then
	call connecter(ok)
	if (.not.ok) then
		call logger('Failed to make TCP connections')
		return
	endif
endif
call setup(ncpu,infile,outfile,ok)
if (ok) then
	clear_to_send = .true.
	simulation_start = .true.
	istep = 0
	res = 0
else
	call logger('=== Setup failed ===')
	res = 1
	stop
endif
return

end subroutine

end module

