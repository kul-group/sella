# cython: language_level=3

# cimports

cimport cython

from libc.math cimport fabs, exp, pi, sqrt, copysign
from libc.string cimport memset
from libc.stdint cimport uint8_t

from scipy.linalg.cython_blas cimport daxpy, ddot, dnrm2, dgemv, dcopy

from sella.utilities.blas cimport my_ddot, my_daxpy, my_dgemv
from sella.utilities.math cimport (vec_sum, mgs, cross,
                                   normalize, mppi)
from sella.internal.int_eval cimport (cart_to_bond, cart_to_angle,
                                      cart_to_dihedral)

# imports
import warnings
import numpy as np
from ase import Atoms, units
from ase.data import covalent_radii

# Constants for BLAS/LAPACK calls
cdef double DNUNITY = -1.
cdef double DZERO = 0.
cdef double DUNITY = 1.

cdef int UNITY = 1
cdef int THREE = 3

@cython.boundscheck(True)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline double _h0_bond(double rab, double rcovab, double conv,
                            double Ab=0.3601, double Bb=1.944) nogil:
    return Ab * exp(-Bb * (rab - rcovab)) * conv


@cython.boundscheck(True)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline double _h0_angle(double rab, double rbc, double rcovab,
                             double rcovbc, double conv, double Aa=0.089,
                             double Ba=0.11, double Ca=0.44,
                             double Da=-0.42) nogil:
    return ((Aa + Ba * exp(-Ca * (rab + rbc - rcovab - rcovbc))
             / (rcovab * rcovbc)**Da) * conv)


@cython.boundscheck(True)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline double _h0_dihedral(double rbc, double rcovbc, int L, double conv,
                                double At=0.0015, double Bt=14.0,
                                double Ct=2.85, double Dt=0.57,
                                double Et=4.00) nogil:
    return ((At + Bt * L**Dt * exp(-Ct * (rbc - rcovbc))
             / (rbc * rcovbc)**Et) * conv)


cdef class CartToInternal:
    def __init__(self, atoms, *args, dummies=None, **kwargs):
        if self.nreal <= 0:
            raise ValueError("Must have at least 1 atom!")
        self.nmin = min(self.nq, self.nx)
        self.nmax = max(self.nq, self.nx)

        # Allocate arrays
        #
        # We use memoryview and numpy to initialize these arrays, because
        # some of the arrays may have a dimension of size 0, which
        # cython.view.array does not permit.
        self.pos = memoryview(np.zeros((self.natoms, 3), dtype=np.float64))
        self.dx1 = memoryview(np.zeros(3, dtype=np.float64))
        self.dx2 = memoryview(np.zeros(3, dtype=np.float64))
        self.dx3 = memoryview(np.zeros(3, dtype=np.float64))
        self.q1 = memoryview(np.zeros(self.nq, dtype=np.float64))
        self.dq = memoryview(np.zeros((self.nq, self.natoms, 3),
                                      dtype=np.float64))
        self.d2q_bonds = memoryview(np.zeros((self.nbonds, 2, 3, 2, 3),
                                             dtype=np.float64))
        self.d2q_angles = memoryview(np.zeros((self.nangles, 3, 3, 3, 3),
                                              dtype=np.float64))
        self.d2q_dihedrals = memoryview(np.zeros((self.ndihedrals, 4, 3, 4, 3),
                                                 dtype=np.float64))
        self.d2q_angle_sums = memoryview(np.zeros((self.nangle_sums, 4, 3,
                                                   4, 3), dtype=np.float64))
        self.d2q_angle_diffs = memoryview(np.zeros((self.nangle_diffs, 4, 3,
                                                    4, 3), dtype=np.float64))
        self.work1 = memoryview(np.zeros((11, 3, 3, 3), dtype=np.float64))
        self.work2 = memoryview(np.zeros((self.natoms, 3), dtype=np.float64))

        # Things for SVD
        self.lwork = 2 * max(3 * self.nmin + self.nmax, 5 * self.nmin, 1)
        self.work3 = memoryview(np.zeros(self.lwork, dtype=np.float64))

        self.sing = memoryview(np.zeros(self.nmin, dtype=np.float64))
        self.Uint = memoryview(np.zeros((self.nmax, self.nmax),
                                        dtype=np.float64))
        self.Uext = memoryview(np.zeros((self.nmax, self.nmax),
                                        dtype=np.float64))
        self.Binv = memoryview(np.zeros((self.nx, self.nq), dtype=np.float64))
        self.Usvd = memoryview(np.zeros((self.nmax, self.nmax),
                                        dtype=np.float64))
        self.grad = False
        self.curv = False
        self.nint = -1
        self.next = -1
        self.calc_required = True

    def __cinit__(CartToInternal self,
                  atoms,
                  *args,
                  int[:, :] cart=None,
                  int[:, :] bonds=None,
                  int[:, :] angles=None,
                  int[:, :] dihedrals=None,
                  int[:, :] angle_sums=None,
                  int[:, :] angle_diffs=None,
                  dummies=None,
                  int[:] dinds=None,
                  double atol=15,
                  **kwargs):

        cdef int i, a, b
        cdef size_t sd = sizeof(double)

        self.nreal = len(atoms)
        if self.nreal <= 0:
            return

        if dummies is None:
            self.ndummies = 0
        else:
            self.ndummies = len(dummies)

        self.natoms = self.nreal + self.ndummies

        self.rcov = memoryview(np.zeros(self.natoms, dtype=np.float64))
        for i in range(self.nreal):
            self.rcov[i] = covalent_radii[atoms.numbers[i]].copy()
        for i in range(self.ndummies):
            self.rcov[self.nreal + i] = covalent_radii[0].copy()

        bmat_np = np.zeros((self.natoms, self.natoms), dtype=np.uint8)
        self.bmat = memoryview(bmat_np)

        self.nx = 3 * self.natoms

        if cart is None:
            self.cart = memoryview(np.empty((0, 2), dtype=np.int32))
        else:
            self.cart = cart
        self.ncart = len(self.cart)

        if bonds is None:
            self.bonds = memoryview(np.empty((0, 2), dtype=np.int32))
        else:
            self.bonds = bonds
        self.nbonds = len(self.bonds)

        for i in range(self.nbonds):
            a = self.bonds[i, 0]
            b = self.bonds[i, 1]
            self.bmat[a, b] = self.bmat[b, a] = True

        if angles is None:
            self.angles = memoryview(np.empty((0, 3), dtype=np.int32))
        else:
            self.angles = angles
        self.nangles = len(self.angles)

        if dihedrals is None:
            self.dihedrals = memoryview(np.empty((0, 4), dtype=np.int32))
        else:
            self.dihedrals = dihedrals
        self.ndihedrals = len(self.dihedrals)

        if angle_sums is None:
            self.angle_sums = memoryview(np.empty((0, 4), dtype=np.int32))
        else:
            self.angle_sums = angle_sums
        self.nangle_sums = len(self.angle_sums)

        if angle_diffs is None:
            self.angle_diffs = memoryview(np.empty((0, 4), dtype=np.int32))
        else:
            self.angle_diffs = angle_diffs
        self.nangle_diffs = len(self.angle_diffs)

        if dinds is None:
            self.dinds = memoryview(-np.ones(self.nreal, dtype=np.int32))
        else:
            self.dinds = dinds

        self.nq = (self.ncart + self.nbonds + self.nangles
                   + self.ndihedrals + self.nangle_sums + self.nangle_diffs)

        self.atol = pi * atol / 180.


    def get_q(self, double[:, :] pos, double[:, :] dummypos=None):
        cdef int info
        with nogil:
            info = self._update(pos, dummypos, False, False)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))

        # We use np.array() instead of np.asarray() because we want to
        # return a copy.
        return np.array(self.q1)

    def get_B(self, double[:, :] pos, double[:, :] dummypos=None):
        cdef int info
        with nogil:
            info = self._update(pos, dummypos, True, False)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))

        return np.array(self.dq).reshape((self.nq, self.nx))

    def get_D(self, double[:, :] pos, double[:, :] dummypos=None):
        cdef int info
        with nogil:
            info = self._update(pos, dummypos, True, True)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))

        return D2q(self.natoms, self.ncart,
                   self.bonds, self.angles, self.dihedrals, self.angle_sums,
                   self.angle_diffs, self.d2q_bonds,
                   self.d2q_angles, self.d2q_dihedrals, self.d2q_angle_sums,
                   self.d2q_angle_diffs)

    cdef bint _validate_pos(CartToInternal self, double[:, :] pos,
                            double[:, :] dummypos=None) nogil:
        cdef int n_in = pos.shape[0]
        if dummypos is not None:
            if dummypos.shape[1] != 3:
                return False
            n_in += dummypos.shape[0]
        else:
            if self.ndummies > 0:
                return False

        if n_in != self.pos.shape[0] or pos.shape[1] != 3:
            return False
        return True

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef bint geom_changed(CartToInternal self, double[:, :] pos,
                           double[:, :] dummypos=None) nogil:
        cdef int i, j
        for i in range(self.nreal):
            for j in range(3):
                if self.pos[i, j] != pos[i, j]:
                    return True

        for i in range(self.ndummies):
            for j in range(3):
                if self.pos[self.nreal + i, j] != dummypos[i, j]:
                    return True

        return False

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _update(CartToInternal self,
                     double[:, :] pos,
                     double[:, :] dummypos=None,
                     bint grad=False,
                     bint curv=False,
                     bint force=False) nogil except -1:
        if not self._validate_pos(pos, dummypos):
            return -1
        # The purpose of this check is to determine whether the positions
        # array has been changed at all since the last internal coordinate
        # evaluation, which is why we are doing exact floating point
        # comparison with ==.
        if not self.calc_required and not force:
            if (self.grad or not grad) and (self.curv or not curv):
                if not self.geom_changed(pos, dummypos):
                    return 0
        self.calc_required = True
        self.grad = grad or curv
        self.curv = curv
        cdef size_t n, m, i, j, k, l
        cdef int info, err
        cdef size_t sd = sizeof(double)

        # Zero out our arrays
        memset(&self.q1[0], 0, self.nq * sd)
        memset(&self.dq[0, 0, 0], 0, self.nq * self.nx * sd)

        # I'm not sure why these "> 0" checks are necessary; according to the
        # C standard, memset accepts a length of 0 (though it results in a
        # no-op), but Cython keeps giving out-of-bounds errors. Maybe it's
        # because indexing memoryviews of size 0 doesn't work?
        if self.nbonds > 0:
            memset(&self.d2q_bonds[0, 0, 0, 0, 0], 0,
                   self.nbonds * 36 * sd)
        if self.nangles > 0:
            memset(&self.d2q_angles[0, 0, 0, 0, 0], 0,
                   self.nangles * 81 * sd)
        if self.ndihedrals > 0:
            memset(&self.d2q_dihedrals[0, 0, 0, 0, 0], 0,
                   self.ndihedrals * 144 * sd)
        if self.nangle_sums > 0:
            memset(&self.d2q_angle_sums[0, 0, 0, 0, 0], 0,
                   self.nangle_sums * 144 * sd)
        if self.nangle_diffs > 0:
            memset(&self.d2q_angle_diffs[0, 0, 0, 0, 0], 0,
                   self.nangle_diffs * 144 * sd)
        memset(&self.work1[0, 0, 0, 0], 0, 297 * sd)
        memset(&self.work2[0, 0], 0, self.nx * sd)

        self.pos[:self.nreal, :] = pos
        if dummypos is not None:
            self.pos[self.nreal:, :] = dummypos

        for n in range(self.ncart):
            i = self.cart[n, 0]
            j = self.cart[n, 1]
            self.q1[n] = self.pos[j, i]
            self.dq[n, j, i] = 1.
            # d2q is the 0 matrix for cartesian coords

        m = self.ncart
        for n in range(self.nbonds):
            i = self.bonds[n, 0]
            j = self.bonds[n, 1]
            err = vec_sum(self.pos[j], self.pos[i], self.dx1, -1.)
            if err != 0: return err
            info = cart_to_bond(i, j, self.dx1, &self.q1[m + n],
                                self.dq[m + n], self.d2q_bonds[n], grad, curv)
            if info < 0: return info

        m += self.nbonds
        for n in range(self.nangles):
            i = self.angles[n, 0]
            j = self.angles[n, 1]
            k = self.angles[n, 2]
            err = vec_sum(self.pos[k], self.pos[j], self.dx2, -1.)
            if err != 0: return err
            err = vec_sum(self.pos[j], self.pos[i], self.dx1, -1.)
            if err != 0: return err
            info = cart_to_angle(i, j, k, self.dx1, self.dx2, &self.q1[m + n],
                                 self.dq[m + n], self.d2q_angles[n],
                                 self.work1, grad, curv)
            if info < 0: return info

        m += self.nangles
        for n in range(self.ndihedrals):
            i = self.dihedrals[n, 0]
            j = self.dihedrals[n, 1]
            k = self.dihedrals[n, 2]
            l = self.dihedrals[n, 3]
            err = vec_sum(self.pos[l], self.pos[k], self.dx3, -1.)
            if err != 0: return err
            err = vec_sum(self.pos[k], self.pos[j], self.dx2, -1.)
            if err != 0: return err
            err = vec_sum(self.pos[j], self.pos[i], self.dx1, -1.)
            if err != 0: return err
            info = cart_to_dihedral(i, j, k, l, self.dx1, self.dx2, self.dx3,
                                    &self.q1[m + n], self.dq[m + n],
                                    self.d2q_dihedrals[n], self.work1,
                                    grad, curv)
            if info < 0:
                return info

        m += self.ndihedrals
        for n in range(self.nangle_sums):
            info = self._angle_sum_diff(self.angle_sums[n], 1.,
                                        &self.q1[m + n], self.dq[m + n],
                                        self.d2q_angle_sums[n], grad, curv)
            if info < 0:
                return info

        m += self.nangle_sums
        for n in range(self.nangle_diffs):
            info = self._angle_sum_diff(self.angle_diffs[n], -1.,
                                        &self.q1[m + n], self.dq[m + n],
                                        self.d2q_angle_diffs[n], grad, curv)
            if info < 0:
                return info

        self.calc_required = False
        self.nint = -1
        return 0

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _U_update(CartToInternal self,
                       double[:, :] pos,
                       double[:, :] dummypos=None,
                       bint force=False) nogil except -1:
        cdef int err = self._update(pos, dummypos, True, False, force)
        if err != 0:
            return err

        if self.nint > 0:
            return 0

        cdef int sddq = self.dq.strides[2] >> 3
        cdef int sdu = self.Uint.strides[1] >> 3
        memset(&self.Uint[0, 0], 0, self.nmax * self.nmax * sizeof(double))
        memset(&self.Uext[0, 0], 0, self.nmax * self.nmax * sizeof(double))

        cdef int i
        if self.nq == 0:
            for i in range(self.nx):
                self.Uext[i, i] = 1.
            self.nint = 0
            self.next = self.nx
            return 0

        for n in range(self.nq):
            dcopy(&self.nx, &self.dq[n, 0, 0], &sddq, &self.Uint[n, 0], &sdu)

        self.nint = mppi(self.nq, self.nx, self.Uint, self.Usvd, self.Uext,
                         self.sing, self.Binv, self.work3)

        if self.nint < 0:
            return self.nint
        self.next = self.nx - self.nint

        self.calc_required = False
        return 0


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _angle_sum_diff(CartToInternal self,
                             int[:] indices,
                             double sign,
                             double* q,
                             double[:, :] dq,
                             double[:, :, :, :] d2q,
                             bint grad,
                             bint curv) nogil:
        cdef int err
        cdef size_t i, j, k, l, m
        cdef size_t sd = sizeof(double)
        memset(&self.work1[0, 0, 0, 0], 0, 297 * sd)
        memset(&self.work2[0, 0], 0, self.nx * sd)
        i = indices[0]
        j = indices[1]
        k = indices[2]
        l = indices[3]

        # First part of the angle sum/diff
        err = vec_sum(self.pos[l], self.pos[j], self.dx2, -1.)
        if err != 0: return err
        err = vec_sum(self.pos[j], self.pos[i], self.dx1, -1.)
        if err != 0: return err
        info = cart_to_angle(i, j, l, self.dx1, self.dx2,
                             q, dq, self.work1[4:7], self.work1,
                             grad, curv)
        # Second part
        self.dx1[:] = self.pos[j, :]
        daxpy(&THREE, &DNUNITY, &self.pos[k, 0], &UNITY, &self.dx1[0], &UNITY)
        err = cart_to_angle(k, j, l, self.dx1, self.dx2,
                            &self.work1[3, 0, 0, 0], self.work2,
                            self.work1[7:10], self.work1,
                            grad, curv)
        if err != 0: return err

        # Combine results
        q[0] += sign * self.work1[3, 0, 0, 0]
        if grad or curv:
            daxpy(&self.nx, &sign, &self.work2[0, 0], &UNITY,
                  &dq[0, 0], &UNITY)

        # Combine second derivatives
        for i in range(3):
            d2q[0, i, 0, :] = self.work1[4, i, 0, :]
            d2q[0, i, 1, :] = self.work1[4, i, 1, :]
            d2q[0, i, 3, :] = self.work1[4, i, 2, :]

            d2q[1, i, 0, :] = self.work1[5, i, 0, :]
            d2q[1, i, 1, :] = self.work1[5, i, 1, :]
            d2q[1, i, 3, :] = self.work1[5, i, 2, :]

            d2q[3, i, 0, :] = self.work1[6, i, 0, :]
            d2q[3, i, 1, :] = self.work1[6, i, 1, :]
            d2q[3, i, 3, :] = self.work1[6, i, 2, :]

        for i in range(3):
            my_daxpy(sign, self.work1[7, i, 0], d2q[2, i, 2])
            my_daxpy(sign, self.work1[7, i, 1], d2q[2, i, 1])
            my_daxpy(sign, self.work1[7, i, 2], d2q[2, i, 3])

            my_daxpy(sign, self.work1[8, i, 0], d2q[1, i, 2])
            my_daxpy(sign, self.work1[8, i, 1], d2q[1, i, 1])
            my_daxpy(sign, self.work1[8, i, 2], d2q[1, i, 3])

            my_daxpy(sign, self.work1[9, i, 0], d2q[3, i, 2])
            my_daxpy(sign, self.work1[9, i, 1], d2q[3, i, 1])
            my_daxpy(sign, self.work1[9, i, 2], d2q[3, i, 3])
        return 0

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def guess_hessian(self, atoms, dummies=None, double h0cart=70.):
        if (dummies is None or len(dummies) == 0) and self.ndummies > 0:
            raise ValueError("Must provide dummy atoms!")
        if len(atoms) != self.nreal:
            raise ValueError("Provided atoms has the wrong number of atoms! "
                             "Expected {}, got {}.".format(self.nreal,
                                                           len(atoms)))
        if dummies is not None:
            if len(dummies) != self.ndummies:
                raise ValueError("Provided dummies has the wrong number of "
                                 " atoms! Expected {}, got {}."
                                 "".format(self.ndummies, len(dummies)))
            atoms = atoms + dummies
        rcov_np = covalent_radii[atoms.numbers].copy() / units.Bohr
        cdef double[:] rcov = memoryview(rcov_np)
        rij_np = atoms.get_all_distances() / units.Bohr
        cdef double[:, :] rij = memoryview(rij_np)

        nbonds_np = np.zeros(self.natoms, dtype=np.int32)
        cdef int[:] nbonds = memoryview(nbonds_np)

        h0_np = np.zeros(self.nq, np.float64)
        cdef double[:] h0 = memoryview(h0_np)

        cdef int i
        cdef int n
        cdef int a, b, c, d
        cdef double Hartree = units.Hartree
        cdef double Bohr = units.Bohr
        cdef double rcovab, rcovbc
        cdef double conv

        # FIXME: for some reason, this fails at runtime when the gil
        # has been released
        with nogil:
            for i in range(self.nbonds):
                nbonds[self.bonds[i, 0]] += 1
                nbonds[self.bonds[i, 1]] += 1

            for i in range(self.nreal):
                if self.dinds[i] != -1:
                    nbonds[i] += 1
                    nbonds[self.dinds[i]] += 1

            n = 0
            for i in range(self.ncart):
                h0[n] = h0cart
                n += 1

            conv = Hartree / Bohr**2
            for i in range(self.nbonds):
                a = self.bonds[i, 0]
                b = self.bonds[i, 1]
                h0[n] = _h0_bond(rij[a, b], rcov[a] + rcov[b], conv)
                #h0[n] = self._h0_bond(self.bonds[i, 0], self.bonds[i, 1],
                #                      rij, rcov, conv)
                n += 1

            conv = Hartree
            for i in range(self.nangles):
                a = self.angles[i, 0]
                b = self.angles[i, 1]
                c = self.angles[i, 2]
                h0[n] = _h0_angle(rij[a, b], rij[b, c], rcov[a] + rcov[b],
                                  rcov[b] + rcov[c], conv)
                #h0[n] = self._h0_angle(self.angles[i, 0], self.angles[i, 1],
                #                       self.angles[i, 2], rij, rcov, conv)
                n += 1

            for i in range(self.ndihedrals):
                b = self.dihedrals[i, 1]
                c = self.dihedrals[i, 2]
                h0[n] = _h0_dihedral(rij[b, c], rcov[b] + rcov[c],
                                     nbonds[b] + nbonds[c] - 2, conv)
                #h0[n] = self._h0_dihedral(self.dihedrals[i, 0],
                #                          self.dihedrals[i, 1],
                #                          self.dihedrals[i, 2],
                #                          self.dihedrals[i, 3],
                #                          nbonds, rij, rcov, conv)
                n += 1

            for i in range(self.nangle_sums):
                a = self.angle_sums[i, 0]
                b = self.angle_sums[i, 1]
                c = self.angle_sums[i, 2]
                h0[n] = _h0_angle(rij[a, b], rij[b, c], rcov[a] + rcov[b],
                                  rcov[b] + rcov[c], conv)
                #h0[n] = self._h0_angle(self.angle_sums[i, 0],
                #                       self.angle_sums[i, 1],
                #                       self.angle_sums[i, 3],
                #                       rij, rcov, conv)
                #h0[n] += self._h0_angle(self.angle_sums[i, 2],
                #                        self.angle_sums[i, 1],
                #                        self.angle_sums[i, 3],
                #                        rij, rcov, conv)
                n += 1

            for i in range(self.nangle_diffs):
                a = self.angle_diffs[i, 0]
                b = self.angle_diffs[i, 1]
                c = self.angle_diffs[i, 2]
                h0[n] = _h0_angle(rij[a, b], rij[b, c], rcov[a] + rcov[b],
                                  rcov[b] + rcov[c], conv)
                #h0[n] = self._h0_angle(self.angle_diffs[i, 0],
                #                       self.angle_diffs[i, 1],
                #                       self.angle_diffs[i, 3],
                #                       rij, rcov, conv)
                #h0[n] -= self._h0_angle(self.angle_diffs[i, 2],
                #                        self.angle_diffs[i, 1],
                #                        self.angle_diffs[i, 3],
                #                        rij, rcov, conv)
                n += 1

        return np.diag(np.abs(h0_np))


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef double _h0_bond(CartToInternal self, int a, int b, double[:, :] rij,
                         double[:] rcov, double conv, double Ab=0.3601,
                         double Bb=1.944) nogil:
        return Ab * exp(-Bb * (rij[a, b] - rcov[a] - rcov[b])) * conv


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef double _h0_angle(CartToInternal self, int a, int b, int c,
                          double[:, :] rij, double[:] rcov, double conv,
                          double Aa=0.089, double Ba=0.11, double Ca=0.44,
                          double Da=-0.42) nogil:
        cdef double rcovab = rcov[a] + rcov[b]
        cdef double rcovbc = rcov[b] + rcov[c]
        return ((Aa + Ba * exp(-Ca * (rij[a, b] + rij[b, c] - rcovab - rcovbc))
                 / (rcovab * rcovbc)**Da) * conv)


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef double _h0_dihedral(CartToInternal self, int a, int b, int c, int d,
                             int[:] nbonds, double[:, :] rij, double[:] rcov,
                             double conv, double At=0.0015, double Bt=14.0,
                             double Ct=2.85, double Dt=0.57,
                             double Et=4.00) nogil:
        cdef double rcovbc = rcov[b] + rcov[c]
        cdef int L = nbonds[b] + nbonds[c] - 2
        return ((At + Bt * L**Dt * exp(-Ct * (rij[b, c] - rcovbc))
                 / (rij[b, c] * rcovbc)**Et) * conv)


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def get_Uext(self, double[:, :] pos, double[:, :] dummypos=None):
        with nogil:
            info = self._U_update(pos, dummypos)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))

        return np.array(self.Uext[:self.nx, :self.next])


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def get_Uint(self, double[:, :] pos, double[:, :] dummypos=None):
        with nogil:
            info = self._U_update(pos, dummypos)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))

        return np.array(self.Uint[:self.nx, :self.nint])


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def get_Binv(self, double[:, :] pos, double[:, :] dummypos=None):
        with nogil:
            info = self._U_update(pos, dummypos)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))

        return np.array(self.Binv)

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(False)
    def dq_wrap(CartToInternal self, double[:] dq):
        dq_out_np = np.zeros_like(dq)
        cdef double[:] dq_out = memoryview(dq_out_np)
        dq_out[:] = dq[:]
        cdef int ncba = self.ncart + self.nbonds + self.nangles
        cdef int i
        with nogil:
            for i in range(self.ndihedrals):
                dq_out[ncba + i] = (dq_out[ncba + i] + pi) % (2 * pi) - pi
        return dq_out_np

    def check_for_bad_internal(CartToInternal self, double[:, :] pos,
                               double[:, :] dummypos):
        cdef int info
        with nogil:
            info = self._update(pos, dummypos, False, False)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}"
                               "".format(info))
        cdef int start
        cdef int i, j
        cdef bint bad = False
        dx_np = np.zeros(3, dtype=np.float64)
        cdef double[:] dx = memoryview(dx_np)
        cdef int sddx = dx.strides[0] >> 3
        cdef double dist
        cdef double factr
        with nogil:
            start = self.ncart + self.nbonds
            for i in range(self.nangles):
                if not (self.atol < self.q1[start + i] < pi - self.atol):
                    bad = True
                    break

            if not bad:
                # Ignore dummy atoms for this check
                for i in range(self.nreal - 1):
                    for j in range(i + 1, self.nreal):
                        if self.bmat[i, j]:
                            factr = 0.5
                        else:
                            factr = 1.25
                        info = vec_sum(self.pos[i], self.pos[j], dx, -1.)
                        if info != 0:  break
                        dist = dnrm2(&THREE, &dx[0], &sddx)
                        if dist < factr * (self.rcov[i] + self.rcov[j]):
                            bad = True
                            break
                    if bad or info != 0:  break

            # FIXME: implement bond distance check in peswrapper
            ## Check for too-short bonds
            #start = self.ncart
            #for i in range(self.nbonds):
            #    if self.q1[start + i] < 0.5:  # FIXME: make this a parameter
            #        bad = True
            #        break

            ## Check for near-linear angles
            #if not bad:
            #    start += self.nbonds
            #    for i in range(self.nangles):
            #        if not (self.atol < self.q1[start + i] < pi - self.atol):
            #            bad = True
            #            break
        if info != 0:
            raise RuntimeError("Failed while checking for bad internals!")
        return bad


cdef class Constraints(CartToInternal):
    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def __cinit__(Constraints self,
                  atoms,
                  double[:] target,
                  *args,
                  bint proj_trans=True,
                  bint proj_rot=True,
                  **kwargs):
        self.target = memoryview(np.zeros(self.nq, dtype=np.float64))
        self.target[:len(target)] = target[:]
        self.proj_trans = proj_trans
        self.proj_rot = proj_rot
        self.rot_axes = memoryview(np.eye(3, dtype=np.float64))
        self.rot_center = memoryview(atoms.positions.mean(0))

        cdef int npbc = atoms.pbc.sum()
        cdef int i
        if self.proj_rot:
            if npbc == 0:
                self.nrot = 3
            elif npbc == 1:
                self.nrot = 1
                for i, dim in enumerate(atoms.pbc):
                    if dim:
                        self.rot_axes[0, :] = atoms.cell[dim, :]
                normalize(self.rot_axes[0])
            else:
                self.proj_rot = False
                self.nrot = 0
        else:
            self.nrot = 0

        if self.nrot > 0 and self.ncart > 0:
            warnings.warn("Projection of rotational degrees of freedom is not "
                          "currently implemented for systems with fixed atom "
                          "constraints. Disabling projection of rotational "
                          "degrees of freedom.")
            self.proj_rot = False
            self.nrot = 0

        # Ured is fixed, so we initialize it here
        fixed_np = np.zeros((self.natoms, 3), dtype=np.uint8)
        cdef uint8_t[:, :] fixed = memoryview(fixed_np)

        self.Ured = memoryview(np.zeros((self.nx, self.nx - self.ncart),
                                        dtype=np.float64))
        self.trans_dirs = memoryview(np.zeros(3, dtype=np.uint8))
        self.tvecs = memoryview(np.zeros((3, self.nx), dtype=np.float64))

        cdef int n, j
        cdef double invsqrtnat = sqrt(1. / self.natoms)
        with nogil:
            if self.proj_trans:
                for j in range(3):
                    self.trans_dirs[j] = True
            for n in range(self.ncart):
                i = self.cart[n, 0]
                j = self.cart[n, 1]
                fixed[j, i] = True
                self.trans_dirs[i] = False
            n = 0
            for i in range(self.natoms):
                for j in range(3):
                    if fixed[i, j]:
                        continue
                    self.Ured[3 * i + j, n] = 1.
                    n += 1

            self.ntrans = 0
            for j in range(3):
                if self.trans_dirs[j]:
                    for i in range(self.natoms):
                        self.tvecs[self.ntrans, 3 * i + j] = invsqrtnat
                    self.ntrans += 1

        if self.ntrans == 0:
            self.proj_trans = False

        self.ninternal = self.nq
        self.nq += self.nrot + self.ntrans

    def __init__(Constraints self,
                 atoms,
                 double[:] target,
                 *args,
                 **kwargs):
        CartToInternal.__init__(self, atoms, *args, **kwargs)
        self.rot_vecs = memoryview(np.zeros((3, 3), dtype=np.float64))

        self.rvecs = memoryview(np.zeros((3, self.nx), dtype=np.float64))
        self.calc_res = False

        self.q1 = memoryview(np.zeros(self.nq, dtype=np.float64))
        self.dq = memoryview(np.zeros((self.nq, self.natoms, 3),
                                      dtype=np.float64))
        self.res = memoryview(np.zeros(self.nq, dtype=np.float64))

        if self.proj_rot:
            self.rot_axes = memoryview(np.eye(3, dtype=np.float64))
            self.center = memoryview(atoms.positions.mean(0))

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _update(Constraints self,
                     double[:, :] pos,
                     double[:, :] dummypos=None,
                     bint grad=False,
                     bint curv=False,
                     bint force=False) nogil except -1:
        if not self._validate_pos(pos, dummypos):
            return -1
        if not self.calc_required and not force:
            if (self.grad or not grad) and (self.curv or not curv):
                if not self.geom_changed(pos, dummypos):
                    return 0

        cdef int i, err, sddq, sdt, ntot, sdr
        self.calc_res = False
        if self.nq == 0:
            return 0
        memset(&self.res[0], 0, self.nq * sizeof(double))
        err = CartToInternal._update(self, pos, dummypos, grad,
                                     curv, True)
        if err != 0:
            self.calc_required = True
            return err

        if not self.grad:
            return 0

        if self.proj_trans:
            sddq = self.dq.strides[2] >> 3
            sdt = self.tvecs.strides[1] >> 3
            ntot = self.ntrans * self.nx
            dcopy(&ntot, &self.tvecs[0, 0], &sdt,
                  &self.dq[self.ninternal, 0, 0], &sddq)

        if self.proj_rot:
            err = self.project_rotation()
            if err != 0: return err

            sdr = self.rvecs.strides[1] >> 3
            ntot = self.nrot * self.nx
            dcopy(&ntot, &self.rvecs[0, 0], &sdr,
                  &self.dq[self.ninternal + self.ntrans, 0, 0], &sddq)

        return 0


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int project_rotation(Constraints self) nogil:
        cdef int i, j
        for i in range(self.nrot):
            for j in range(self.natoms):
                cross(self.rot_axes[i], self.pos[j],
                      self.rvecs[i, 3*j : 3*(j+1)])
        cdef int err = mgs(self.rvecs[:self.nrot, :].T, self.tvecs.T)
        if err < 0: return err
        if err < self.nrot: return -1
        return 0


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def get_res(self, double[:, :] pos, double[:, :] dummypos=None):
        cdef int info
        with nogil:
            info = self._update(pos, dummypos, False, False)
        if info < 0:
            raise RuntimeError("Internal update failed with error code {}",
                               "".format(info))
        if self.calc_res:
            return np.asarray(self.res)
        cdef int i, n
        with nogil:
            for i in range(self.ninternal):
                self.res[i] = self.q1[i] - self.target[i]

            n = self.ncart + self.nbonds + self.nangles
            # Dihedrals are periodic on the range -pi to pi
            for i in range(self.ndihedrals):
                self.res[n + i] = (pi + self.res[n + i]) % (2 * pi) #- pi
                self.res[n + i] -= copysign(pi, self.res[n + i])
        self.calc_res = True
        return np.asarray(self.res)

    def get_drdx(self, double[:, :] pos, double[:, :] dummypos=None):
        return self.get_B(pos, dummypos)

    def get_Ured(self):
        return np.asarray(self.Ured)

    def get_Ucons(self, double[:, :] pos, double[:, :] dummypos=None):
        return self.get_Uint(pos, dummypos)

    def get_Ufree(self, double[:, :] pos, double[:, :] dummypos=None):
        return self.get_Uext(pos, dummypos)

    def guess_hessian(self, atoms, double h0cart=70.):
        raise NotImplementedError


cdef class D2q:
    def __cinit__(D2q self,
                  int natoms,
                  int ncart,
                  int[:, :] bonds,
                  int[:, :] angles,
                  int[:, :] dihedrals,
                  int[:, :] angle_sums,
                  int[:, :] angle_diffs,
                  double[:, :, :, :, :] Dbonds,
                  double[:, :, :, :, :] Dangles,
                  double[:, :, :, :, :] Ddihedrals,
                  double[:, :, :, :, :] Dangle_sums,
                  double[:, :, :, :, :] Dangle_diffs):
        self.natoms = natoms
        self.nx = 3 * self.natoms

        self.ncart = ncart

        self.bonds = bonds
        self.nbonds = len(self.bonds)

        self.angles = angles
        self.nangles = len(self.angles)

        self.dihedrals = dihedrals
        self.ndihedrals = len(self.dihedrals)

        self.angle_sums = angle_sums
        self.nangle_sums = len(self.angle_sums)

        self.angle_diffs = angle_diffs
        self.nangle_diffs = len(self.angle_diffs)

        self.nq = (self.nbonds + self.nangles + self.ndihedrals
                   + self.nangle_sums + self.nangle_diffs)

        self.Dbonds = memoryview(np.zeros((self.nbonds, 2, 3, 2, 3),
                                          dtype=np.float64))
        self.Dbonds[...] = Dbonds

        self.Dangles = memoryview(np.zeros((self.nangles, 3, 3, 3, 3),
                                           dtype=np.float64))
        self.Dangles[...] = Dangles

        self.Ddihedrals = memoryview(np.zeros((self.ndihedrals, 4, 3, 4, 3),
                                              dtype=np.float64))
        self.Ddihedrals[...] = Ddihedrals

        self.Dangle_sums = memoryview(np.zeros((self.nangle_sums, 4, 3, 4, 3),
                                               dtype=np.float64))
        self.Dangle_sums[...] = Dangle_sums

        self.Dangle_diffs = memoryview(np.zeros((self.nangle_diffs, 4, 3, 4, 3),
                                                dtype=np.float64))
        self.Dangle_diffs[...] = Dangle_diffs

        self.work1 = memoryview(np.zeros((4, 3), dtype=np.float64))
        self.work2 = memoryview(np.zeros((4, 3), dtype=np.float64))
        self.work3 = memoryview(np.zeros((4, 3), dtype=np.float64))

        self.sw1 = self.work1.strides[1] >> 3
        self.sw2 = self.work2.strides[1] >> 3
        self.sw3 = self.work3.strides[1] >> 3


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def ldot(self, double[:] v1):
        cdef size_t m = self.ncart
        #assert len(v1) == self.nq, (len(v1), self.nq)

        result_np = np.zeros((self.natoms, 3, self.natoms, 3),
                             dtype=np.float64)
        cdef double[:, :, :, :] res = memoryview(result_np)
        with nogil:
            self._ld(m, self.nbonds, 2, self.bonds, self.Dbonds, v1, res)
            m += self.nbonds
            self._ld(m, self.nangles, 3, self.angles, self.Dangles, v1, res)
            m += self.nangles
            self._ld(m, self.ndihedrals, 4, self.dihedrals, self.Ddihedrals,
                     v1, res)
            m += self.ndihedrals
            self._ld(m, self.nangle_sums, 4, self.angle_sums, self.Dangle_sums,
                     v1, res)
            m += self.nangle_sums
            self._ld(m, self.nangle_diffs, 4, self.angle_diffs,
                     self.Dangle_diffs, v1, res)
        return result_np.reshape((self.nx, self.nx))

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _ld(D2q self,
                 size_t start,
                 size_t nq,
                 size_t nind,
                 int[:, :] q,
                 double[:, :, :, :, :] D2,
                 double[:] v,
                 double[:, :, :, :] res) nogil except -1:
        cdef int err
        cdef size_t n, i, a, ai, b, bi

        for n in range(nq):
            for a in range(nind):
                ai = q[n, a]
                for b in range(nind):
                    bi = q[n, b]
                    for i in range(3):
                        err = my_daxpy(v[start + n], D2[n, a, i, b],
                                       res[ai, i, bi])
                        if err != 0:
                            return err
        return 0

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def rdot(self, double[:] v1):
        cdef size_t m = self.ncart
        assert len(v1) == self.nx

        result_np = np.zeros((self.nq, self.natoms, 3), dtype=np.float64)
        cdef double[:, :, :] res = memoryview(result_np)
        with nogil:
            self._rd(m, self.nbonds, 2, self.bonds, self.Dbonds, v1, res)
            m += self.nbonds
            self._rd(m, self.nangles, 3, self.angles, self.Dangles, v1, res)
            m += self.nangles
            self._rd(m, self.ndihedrals, 4, self.dihedrals, self.Ddihedrals,
                     v1, res)
            m += self.ndihedrals
            self._rd(m, self.nangle_sums, 4, self.angle_sums, self.Dangle_sums,
                     v1, res)
            m += self.nangle_sums
            self._rd(m, self.nangle_diffs, 4, self.angle_diffs,
                     self.Dangle_diffs, v1, res)
        return result_np.reshape((self.nq, self.nx))


    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _rd(D2q self,
                 size_t start,
                 size_t nq,
                 size_t nind,
                 int[:, :] q,
                 double[:, :, :, :, :] D2,
                 double[:] v,
                 double[:, :, :] res) nogil except -1:
        cdef size_t n, a, ai
        cdef int sv = v.strides[0] >> 3
        cdef int sres = res.strides[2] >> 3
        cdef int dim = 3 * nind
        cdef int ldD2 = dim * (D2.strides[4] >> 3)
        for n in range(nq):
            for a in range(nind):
                ai = q[n, a]
                self.work1[a, :] = v[3*ai : 3*(ai+1)]
            dgemv('N', &dim, &dim, &DUNITY, &D2[n, 0, 0, 0, 0], &ldD2,
                  &self.work1[0, 0], &self.sw1, &DZERO,
                  &self.work2[0, 0], &self.sw2)
            for a in range(nind):
                ai = q[n, a]
                res[start + n, ai, :] = self.work2[a, :]
        return 0

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def ddot(self, double[:] v1, double[:] v2):
        cdef size_t m = self.ncart
        assert len(v1) == self.nx
        assert len(v2) == self.nx

        result_np = np.zeros(self.nq, dtype=np.float64)
        cdef double[:] res = memoryview(result_np)
        with nogil:
            self._dd(m, self.nbonds, 2, self.bonds, self.Dbonds, v1, v2, res)
            m += self.nbonds
            self._dd(m, self.nangles, 3, self.angles, self.Dangles, v1, v2,
                     res)
            m += self.nangles
            self._dd(m, self.ndihedrals, 4, self.dihedrals, self.Ddihedrals,
                     v1, v2, res)
            m += self.ndihedrals
            self._dd(m, self.nangle_sums, 4, self.angle_sums, self.Dangle_sums,
                     v1, v2, res)
            m += self.nangle_sums
            self._dd(m, self.nangle_diffs, 4, self.angle_diffs,
                     self.Dangle_diffs, v1, v2, res)
        return result_np

    @cython.boundscheck(True)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef int _dd(D2q self,
                 size_t start,
                 size_t nq,
                 size_t nind,
                 int[:, :] q,
                 double[:, :, :, :, :] D2,
                 double[:] v1,
                 double[:] v2,
                 double[:] res) nogil except -1:
        cdef size_t n, a, ai
        cdef int sv1 = v1.strides[0] >> 3
        cdef int sv2 = v2.strides[0] >> 3
        cdef int dim = 3 * nind
        cdef int sD2 = dim * (D2.strides[4] >> 3)
        for n in range(nq):
            for a in range(nind):
                ai = q[n, a]
                self.work1[a, :] = v1[3*ai : 3*(ai+1)]
                self.work2[a, :] = v2[3*ai : 3*(ai+1)]
            dgemv('N', &dim, &dim, &DUNITY, &D2[n, 0, 0, 0, 0], &sD2,
                  &self.work1[0, 0], &self.sw1, &DZERO,
                  &self.work3[0, 0], &self.sw3)
            res[start + n] = ddot(&dim, &self.work2[0, 0], &self.sw2,
                                  &self.work3[0, 0], &self.sw3)
        return 0
