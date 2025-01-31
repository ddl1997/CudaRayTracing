#ifndef _MATERIAL_H_
#define _MATERIAL_H_
#include "Eigen/Dense"
#include "Global.h"


enum Illum {
    DIFFUSE, 
    SPECULAR
};
class Material
{
    private:
        Eigen::Vector3f kd;
        Eigen::Vector3f ks;
        Eigen::Vector3f ka;
        Eigen::Vector3f ke;
        float ns;
        bool has_emit;
        Illum mode;

    public:
        Material()
        {
            kd = Eigen::Vector3f(0.1f, 0.1f, 0.1f);
            ks = Eigen::Vector3f(0.1f, 0.1f, 0.1f);
            ka = Eigen::Vector3f(0.1f, 0.1f, 0.1f);
            ke = Eigen::Vector3f(0.0f, 0.0f, 0.0f);
            has_emit = false;
            ns = 1.0f;
            mode = DIFFUSE;
        }
        Material(Eigen::Vector3f kd, Eigen::Vector3f ks, Eigen::Vector3f ka, Eigen::Vector3f ke, float ns, Illum mode):
        kd(kd), ks(ks), ka(ka), ke(ke), ns(ns), mode(mode)
        {
            if(ke.x() < EPSILON && ke.y() < EPSILON && ke.z() < EPSILON)
                has_emit = false;
            else
                has_emit = true;
        }

        // Getter functions
        Eigen::Vector3f get_kd() const
        {
            return kd;
        }

        Eigen::Vector3f get_ks() const
        {
            return ks;
        }

        Eigen::Vector3f get_ka() const
        {
            return ka;
        }

        Eigen::Vector3f get_ke() const
        {
            return ke;
        }
        
        float get_ns() const
        {
            return ns;
        }

        bool has_emission() const
        {
            return has_emit;
        }

        Illum get_mode() const
        {
            return mode;
        }
};
#endif