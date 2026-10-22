"""Pose-to-homography construction and the 17-register projective contract.

Rotation maps an output-camera ray to the source-camera frame. Positive angles
are right-handed, in degrees, and R = Rz(roll) @ Ry(yaw) @ Rx(pitch).
Camera coordinates are x right, y down, z forward. This is a rotation-only
view change; scene depth is not needed. Plane homographies may instead be
supplied directly through a 3x3 output_to_ideal configuration.
"""
from __future__ import annotations

import copy
import numpy as np

from .reference import fixed_parameters, float_map, normalized_homography


def rotation_source_from_output(yaw_degrees=0., pitch_degrees=0., roll_degrees=0.):
    yaw, pitch, roll = np.deg2rad([yaw_degrees, pitch_degrees, roll_degrees])
    if not np.isfinite([yaw, pitch, roll]).all():
        raise ValueError("pose angles must be finite")
    cy, sy = np.cos(yaw), np.sin(yaw)
    cp, sp = np.cos(pitch), np.sin(pitch)
    cr, sr = np.cos(roll), np.sin(roll)
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    return rz @ ry @ rx


def pose_config(config, yaw_degrees=0., pitch_degrees=0., roll_degrees=0.):
    """Return a copy with an absolute pose, replacing output_to_ideal.

    The output intrinsics determine the requested field of view. Positive-depth
    validation rejects rays behind the source camera or crossing its horizon.
    """
    result = copy.deepcopy(config)
    ko = np.asarray(result.get("output_camera_matrix", result["camera_matrix"]), dtype=float)
    rotation = rotation_source_from_output(yaw_degrees, pitch_degrees, roll_degrees)
    result["output_to_ideal"] = (ko @ rotation @ np.linalg.inv(ko)).tolist()
    result["projective_positive_depth"] = True
    result["pose"] = {"yaw_degrees": yaw_degrees, "pitch_degrees": pitch_degrees,
                      "roll_degrees": roll_degrees,
                      "convention": "source_from_output; Rz(roll) Ry(yaw) Rx(pitch); right-handed"}
    float_map(result)
    return result


def projective_parameters(config):
    """Old 14 words followed by a20,a21,a22, all signed32 register words."""
    result = copy.deepcopy(config)
    if np.asarray(result.get("output_to_ideal", [[1, 0, 0], [0, 1, 0]])).shape == (2, 3):
        result["output_to_ideal"] = np.vstack([
            result.get("output_to_ideal", [[1, 0, 0], [0, 1, 0]]), [0, 0, 1]]).tolist()
    return fixed_parameters(result)
