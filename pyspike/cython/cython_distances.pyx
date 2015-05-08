#cython: boundscheck=False
#cython: wraparound=False
#cython: cdivision=True

"""
cython_distances.pyx

cython implementation of the isi-, spike- and spike-sync distances

Note: using cython memoryviews (e.g. double[:]) instead of ndarray objects
improves the performance of spike_distance by a factor of 10!

Copyright 2015, Mario Mulansky <mario.mulansky@gmx.net>

Distributed under the BSD License

"""

"""
To test whether things can be optimized: remove all yellow stuff
in the html output::

  cython -a cython_distances.pyx

which gives::

  cython_distances.html

"""

import numpy as np
cimport numpy as np

from libc.math cimport fabs
from libc.math cimport fmax
from libc.math cimport fmin

DTYPE = np.float
ctypedef np.float_t DTYPE_t


############################################################
# isi_distance_cython
############################################################
def isi_distance_cython(double[:] s1, double[:] s2,
                        double t_start, double t_end):

    cdef double isi_value
    cdef int index1, index2, index
    cdef int N1, N2
    cdef double nu1, nu2
    cdef double last_t, curr_t, curr_isi
    isi_value = 0.0
    N1 = len(s1)
    N2 = len(s2)

    # first interspike interval - check if a spike exists at the start time
    if s1[0] > t_start:
        # edge correction
        nu1 = fmax(s1[0]-t_start, s1[1]-s1[0])
        index1 = -1
    else:
        nu1 = s1[1]-s1[0]
        index1 = 0

    if s2[0] > t_start:
        # edge correction
        nu2 = fmax(s2[0]-t_start, s2[1]-s2[0])
        index2 = -1
    else:
        nu2 = s2[1]-s2[0]
        index2 = 0

    last_t = t_start
    curr_isi = fabs(nu1-nu2)/fmax(nu1, nu2)
    index = 1

    with nogil: # release the interpreter to allow multithreading
        while index1+index2 < N1+N2-2:
            # check which spike is next, only if there are spikes left in 1
            # next spike in 1 is earlier, or there are no spikes left in 2
            if (index1 < N1-1) and ((index2 == N2-1) or
                                    (s1[index1+1] < s2[index2+1])):
                index1 += 1
                curr_t = s1[index1]
                if index1 < N1-1:
                    nu1 = s1[index1+1]-s1[index1]
                else:
                    # edge correction
                    nu1 = fmax(t_end-s1[index1], nu1)
            elif (index2 < N2-1) and ((index1 == N1-1) or
                                      (s1[index1+1] > s2[index2+1])):
                index2 += 1
                curr_t = s2[index2]
                if index2 < N2-1:
                    nu2 = s2[index2+1]-s2[index2]
                else:
                    # edge correction
                    nu2 = fmax(t_end-s2[index2], nu2)
            else: # s1[index1+1] == s2[index2+1]
                index1 += 1
                index2 += 1
                curr_t = s1[index1]
                if index1 < N1-1:
                    nu1 = s1[index1+1]-s1[index1]
                else:
                    # edge correction
                    nu1 = fmax(t_end-s1[index1], nu1)
                if index2 < N2-1:
                    nu2 = s2[index2+1]-s2[index2]
                else:
                    # edge correction
                    nu2 = fmax(t_end-s2[index2], nu2)
            # compute the corresponding isi-distance
            isi_value += curr_isi * (curr_t - last_t)
            curr_isi = fabs(nu1 - nu2) / fmax(nu1, nu2)
            last_t = curr_t
            index += 1

        isi_value += curr_isi * (t_end - last_t)
    # end nogil

    return isi_value / (t_end-t_start)


############################################################
# get_min_dist_cython
############################################################
cdef inline double get_min_dist_cython(double spike_time, 
                                       double[:] spike_train,
                                       # use memory view to ensure inlining
                                       # np.ndarray[DTYPE_t,ndim=1] spike_train,
                                       int N,
                                       int start_index,
                                       double t_start, double t_end) nogil:
    """ Returns the minimal distance |spike_time - spike_train[i]| 
    with i>=start_index.
    """
    cdef double d, d_temp
    # start with the distance to the start time
    d = fabs(spike_time - t_start)
    if start_index < 0:
        start_index = 0
    while start_index < N:
        d_temp = fabs(spike_time - spike_train[start_index])
        if d_temp > d:
            return d
        else:
            d = d_temp
        start_index += 1

    # finally, check the distance to end time
    d_temp = fabs(t_end - spike_time)
    if d_temp > d:
        return d
    else:
        return d_temp


############################################################
# isi_avrg_cython
############################################################
cdef inline double isi_avrg_cython(double isi1, double isi2) nogil:
    return 0.5*(isi1+isi2)*(isi1+isi2)
    # alternative definition to obtain <S> ~ 0.5 for Poisson spikes
    # return 0.5*(isi1*isi1+isi2*isi2)


############################################################
# spike_distance_cython
############################################################
def spike_distance_cython(double[:] t1, double[:] t2,
                          double t_start, double t_end):

    cdef int N1, N2, index1, index2, index
    cdef double t_p1, t_f1, t_p2, t_f2, dt_p1, dt_p2, dt_f1, dt_f2
    cdef double isi1, isi2, s1, s2
    cdef double y_start, y_end, t_last, t_current, spike_value
    
    spike_value = 0.0

    N1 = len(t1)
    N2 = len(t2)

    with nogil: # release the interpreter to allow multithreading
        t_last = t_start
        t_p1 = t_start
        t_p2 = t_start
        if t1[0] > t_start:
            # dt_p1 = t2[0]-t_start
            t_f1 = t1[0]
            dt_f1 = get_min_dist_cython(t_f1, t2, N2, 0, t_start, t_end)
            isi1 = fmax(t_f1-t_start, t1[1]-t1[0])
            dt_p1 = dt_f1
            s1 = dt_p1*(t_f1-t_start)/isi1
            index1 = -1
        else:
            t_f1 = t1[1]
            dt_f1 = get_min_dist_cython(t_f1, t2, N2, 0, t_start, t_end)
            dt_p1 = 0.0
            isi1 = t1[1]-t1[0]
            s1 = dt_p1
            index1 = 0
        if t2[0] > t_start:
            # dt_p1 = t2[0]-t_start
            t_f2 = t2[0]
            dt_f2 = get_min_dist_cython(t_f2, t1, N1, 0, t_start, t_end)
            dt_p2 = dt_f2
            isi2 = fmax(t_f2-t_start, t2[1]-t2[0])
            s2 = dt_p2*(t_f2-t_start)/isi2
            index2 = -1
        else:
            t_f2 = t2[1]
            dt_f2 = get_min_dist_cython(t_f2, t1, N1, 0, t_start, t_end)
            dt_p2 = 0.0
            isi2 = t2[1]-t2[0]
            s2 = dt_p2
            index2 = 0

        y_start = (s1*isi2 + s2*isi1) / isi_avrg_cython(isi1, isi2)
        index = 1

        while index1+index2 < N1+N2-2:
            # print(index, index1, index2)
            if (index1 < N1-1) and (t_f1 < t_f2 or index2 == N2-1):
                index1 += 1
                # first calculate the previous interval end value
                s1 = dt_f1*(t_f1-t_p1) / isi1
                # the previous time now was the following time before:
                dt_p1 = dt_f1
                t_p1 = t_f1    # t_p1 contains the current time point
                # get the next time
                if index1 < N1-1:
                    t_f1 = t1[index1+1]
                else:
                    t_f1 = t_end
                t_curr =  t_p1
                s2 = (dt_p2*(t_f2-t_p1) + dt_f2*(t_p1-t_p2)) / isi2
                y_end = (s1*isi2 + s2*isi1)/isi_avrg_cython(isi1, isi2)

                spike_value += 0.5*(y_start + y_end) * (t_curr - t_last)

                # now the next interval start value
                if index1 < N1-1:
                    dt_f1 = get_min_dist_cython(t_f1, t2, N2, index2,
                                                t_start, t_end)
                    isi1 = t_f1-t_p1
                    s1 = dt_p1
                else:
                    dt_f1 = dt_p1
                    isi1 = fmax(t_end-t1[N1-1], t1[N1-1]-t1[N1-2])
                    # s1 needs adjustment due to change of isi1
                    s1 = dt_p1*(t_end-t1[N1-1])/isi1
                # s2 is the same as above, thus we can compute y2 immediately
                y_start = (s1*isi2 + s2*isi1)/isi_avrg_cython(isi1, isi2)
            elif (index2 < N2-1) and (t_f1 > t_f2 or index1 == N1-1):
                index2 += 1
                # first calculate the previous interval end value
                s2 = dt_f2*(t_f2-t_p2) / isi2
                # the previous time now was the following time before:
                dt_p2 = dt_f2
                t_p2 = t_f2    # t_p2 contains the current time point
                # get the next time
                if index2 < N2-1:
                    t_f2 = t2[index2+1]
                else:
                    t_f2 = t_end
                t_curr = t_p2
                s1 = (dt_p1*(t_f1-t_p2) + dt_f1*(t_p2-t_p1)) / isi1
                y_end = (s1*isi2 + s2*isi1) / isi_avrg_cython(isi1, isi2)

                spike_value += 0.5*(y_start + y_end) * (t_curr - t_last)

                # now the next interval start value
                if index2 < N2-1:
                    dt_f2 = get_min_dist_cython(t_f2, t1, N1, index1,
                                                t_start, t_end)
                    isi2 = t_f2-t_p2
                    s2 = dt_p2
                else:
                    dt_f2 = dt_p2
                    isi2 = fmax(t_end-t2[N2-1], t2[N2-1]-t2[N2-2])
                    # s2 needs adjustment due to change of isi2
                    s2 = dt_p2*(t_end-t2[N2-1])/isi2
                # s1 is the same as above, thus we can compute y2 immediately
                y_start = (s1*isi2 + s2*isi1)/isi_avrg_cython(isi1, isi2)
            else: # t_f1 == t_f2 - generate only one event
                index1 += 1
                index2 += 1
                t_p1 = t_f1
                t_p2 = t_f2
                dt_p1 = 0.0
                dt_p2 = 0.0
                t_curr = t_f1
                y_end = 0.0
                spike_value += 0.5*(y_start + y_end) * (t_curr - t_last)
                y_start = 0.0
                if index1 < N1-1:
                    t_f1 = t1[index1+1]
                    dt_f1 = get_min_dist_cython(t_f1, t2, N2, index2,
                                                t_start, t_end)
                    isi1 = t_f1 - t_p1
                else:
                    t_f1 = t_end
                    dt_f1 = dt_p1
                    isi1 = fmax(t_end-t1[N1-1], t1[N1-1]-t1[N1-2])
                if index2 < N2-1:
                    t_f2 = t2[index2+1]
                    dt_f2 = get_min_dist_cython(t_f2, t1, N1, index1,
                                                t_start, t_end)
                    isi2 = t_f2 - t_p2
                else:
                    t_f2 = t_end
                    dt_f2 = dt_p2
                    isi2 = fmax(t_end-t2[N2-1], t2[N2-1]-t2[N2-2])
            index += 1
            t_last = t_curr
        # isi1 = max(t_end-t1[N1-1], t1[N1-1]-t1[N1-2])
        # isi2 = max(t_end-t2[N2-1], t2[N2-1]-t2[N2-2])
        s1 = dt_f1*(t_end-t1[N1-1])/isi1
        s2 = dt_f2*(t_end-t2[N2-1])/isi2
        y_end = (s1*isi2 + s2*isi1) / isi_avrg_cython(isi1, isi2)
        spike_value += 0.5*(y_start + y_end) * (t_end - t_last)
    # end nogil

    # use only the data added above 
    # could be less than original length due to equal spike times
    return spike_value / (t_end-t_start)
